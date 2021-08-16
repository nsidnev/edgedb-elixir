defmodule EdgeDB.Connection do
  use DBConnection

  use EdgeDB.Protocol.Messages

  alias EdgeDB.Connection.{
    QueriesCache,
    QueryBuilder
  }

  alias EdgeDB.Protocol.{
    Codecs,
    Enums,
    Error
  }

  alias EdgeDB.SCRAM

  require Logger

  @default_timeout 15_000
  @max_packet_size 64 * 1024 * 1024
  @tcp_socket_opts [packet: :raw, mode: :binary, active: false]
  @ssl_socket_opts []

  @scram_sha_256 "SCRAM-SHA-256"
  @major_ver 0
  @minor_ver 11
  @minor_ver_min 11

  defmodule State do
    defstruct [
      :socket,
      :user,
      :database,
      :queries_cache,
      :codecs_storage,
      :timeout,
      buffer: <<>>,
      server_key_data: nil,
      server_state: :not_in_transaction
    ]

    @type t() :: %__MODULE__{
            socket: :ssl.sslsocket(),
            user: String.t(),
            database: String.t(),
            timeout: timeout(),
            buffer: bitstring(),
            server_key_data: list(byte()) | nil,
            server_state: Enums.TransactionState.t(),
            queries_cache: QueriesCache.t(),
            codecs_storage: Codecs.Storage.t()
          }

    @spec new(
            :ssl.sslsocket(),
            String.t(),
            String.t(),
            QueriesCache.t(),
            Codecs.Storage.t(),
            timeout()
          ) :: t()
    def new(socket, user, database, queries_cache, codecs_storage, timeout) do
      %__MODULE__{
        socket: socket,
        user: user,
        database: database,
        timeout: timeout,
        queries_cache: queries_cache,
        codecs_storage: codecs_storage
      }
    end
  end

  @type disconnection() :: {:disconnect, Exception.t(), State.t()}

  @impl DBConnection
  def checkin(state) do
    {:ok, state}
  end

  @impl DBConnection
  def checkout(state) do
    {:ok, state}
  end

  @impl DBConnection
  def connect(opts \\ []) do
    endpoints = opts[:endpoints] || []
    user = opts[:user]
    password = opts[:password]
    database = opts[:database]

    connect_opts =
      []
      |> Keyword.merge(@tcp_socket_opts)
      |> Keyword.merge(@ssl_socket_opts)
      |> add_custom_edgedb_ssl_opts(opts)
      |> Keyword.merge(opts[:tcp_options] || [])
      |> Keyword.merge(opts[:ssl_options] || [])

    timeout = opts[:timeout] || @default_timeout

    with {:ok, qc} <- QueriesCache.start_link(),
         {:ok, cs} <- Codecs.Storage.start_link(),
         {:ok, socket} <- open_ssl_connection(endpoints, connect_opts, timeout),
         state = State.new(socket, user, database, qc, cs, timeout),
         {:ok, state} <- handshake(password, state),
         {:ok, state} <- wait_for_server_ready(state) do
      {:ok, state}
    else
      {:error, :no_endpoints} ->
        exc =
          Error.client_connection_error(
            "unable to establish a connection because the endpoints were not passed"
          )

        {:error, exc}

      {:error, connect_errors} when is_list(connect_errors) ->
        connect_error =
          connect_errors
          |> Enum.reverse()
          |> Enum.map_join("\n", fn
            {{{:local, socket_path}, _fd}, reason} ->
              "  * #{socket_path}: #{inspect(reason)}"

            {{host, port}, reason} ->
              "  * #{host}:#{port}: #{inspect(reason)}"
          end)

        exc =
          Error.client_connection_error(
            "unable to establish connection to multiple endpoints:\n\n#{connect_error}"
          )

        {:error, exc}

      {:error, reason} ->
        exc = Error.client_connection_error("unable to establish connection: #{inspect(reason)}")
        {:error, exc}

      {:disconnect, exc, state} ->
        disconnect(exc, state)
        {:error, exc}
    end
  end

  @impl DBConnection
  def disconnect(_exc, %State{socket: socket} = state) do
    with :ok <- send_message(terminate(), state) do
      :ssl.close(socket)
    end
  end

  @impl DBConnection
  def handle_begin(_opts, %State{server_state: server_state} = state)
      when server_state in [:in_transaction, :in_failed_transaction] do
    {status(state), state}
  end

  @impl DBConnection
  def handle_begin(opts, %State{} = state) do
    start_transaction(opts, state)
  end

  @impl DBConnection
  def handle_close(
        %EdgeDB.Query{input_codec: in_codec, output_codec: out_codec} = query,
        _opts,
        state
      )
      when not is_nil(in_codec) and not is_nil(out_codec) do
    close_prepared_query(query, state)
  end

  @impl DBConnection
  def handle_commit(_opts, %State{server_state: server_state} = state)
      when server_state in [:not_in_transaction, :in_failed_transaction] do
    {status(state), state}
  end

  @impl DBConnection
  def handle_commit(_opts, state) do
    commit_transaction(state)
  end

  @impl DBConnection
  def handle_deallocate(_query, _cursor, _opts, state) do
    exc = Error.interface_error("callback handle_deallocate hasn't been implemented")
    {:disconnect, exc, state}
  end

  @impl DBConnection
  def handle_declare(_query, _params, _opts, state) do
    exc = Error.interface_error("callback handle_declare hasn't been implemented")
    {:disconnect, exc, state}
  end

  @impl DBConnection
  def handle_execute(%EdgeDB.Query{cached?: true} = query, params, opts, state) do
    optimistic_execute_query(query, params, opts, state)
  end

  @impl DBConnection
  def handle_execute(%EdgeDB.Query{} = query, params, _opts, state) do
    execute_query(query, params, state)
  end

  @impl DBConnection
  def handle_fetch(_query, _cursor, _opts, state) do
    exc = Error.interface_error("callback handle_fetch hasn't been implemented")
    {:disconnect, exc, state}
  end

  @impl DBConnection
  def handle_prepare(%EdgeDB.Query{} = query, opts, %State{queries_cache: qc} = state) do
    case QueriesCache.get(qc, query.statement, query.cardinality, query.io_format) do
      %EdgeDB.Query{} = cached_query ->
        {:ok, cached_query, state}

      nil ->
        prepare_query(query, opts, state)
    end
  end

  @impl DBConnection
  def handle_rollback(_opts, %State{server_state: server_state} = state)
      when server_state == :not_in_transaction do
    {server_state, state}
  end

  @impl DBConnection
  def handle_rollback(_opts, state) do
    rollback_transaction(state)
  end

  @impl DBConnection
  def handle_status(_opts, state) do
    {status(state), state}
  end

  @impl DBConnection
  def ping(state) do
    {:ok, state}
  end

  defp open_ssl_connection([], _opts, _timeout) do
    {:error, :no_endpoints}
  end

  defp open_ssl_connection([{host, port}], opts, timeout) do
    :ssl.connect(host, port, opts, timeout)
  end

  defp open_ssl_connection(endpoints, opts, timeout) do
    Enum.reduce_while(endpoints, {:error, []}, fn {host, port}, {:error, connect_errors} ->
      case :ssl.connect(host, port, opts, timeout) do
        {:ok, socket} ->
          {:halt, {:ok, socket}}

        {:error, reason} ->
          {:cont, {:error, [{{host, port}, reason} | connect_errors]}}
      end
    end)
  end

  defp add_custom_edgedb_ssl_opts(opts, edgedb_opts) do
    opts =
      cond do
        pem_cert_path = edgedb_opts[:tls_ca_file] ->
          Keyword.put(opts, :cacertfile, pem_cert_path)

        pem_cert_data = edgedb_opts[:tls_ca_data] ->
          {:Certificate, der_cert_data, _cipher_info} =
            pem_cert_data
            |> :public_key.pem_decode()
            |> Enum.find(fn
              {:Certificate, _der_cert_data, _cipher_info} ->
                true

              _other ->
                false
            end)

          Keyword.put(opts, :cacerts, [der_cert_data])

        true ->
          opts
      end

    opts =
      if edgedb_opts[:tls_verify_hostname] do
        Keyword.put(opts, :verify, :verify_peer)
      else
        opts
      end

    Keyword.put(opts, :alpn_advertised_protocols, ["edgedb-binary"])
  end

  defp handshake(password, %State{} = state) do
    message =
      client_handshake(
        major_ver: @major_ver,
        minor_ver: @minor_ver,
        params: [
          connection_param(name: "user", value: state.user),
          connection_param(name: "database", value: state.database)
        ],
        extensions: []
      )

    with :ok <- send_message(message, state) do
      handle_authentication(password, state)
    end
  end

  defp handle_authentication(password, state) do
    with {:ok, {message, buffer}} <- receive_message(state) do
      handle_authentication_flow(message, password, %State{state | buffer: buffer})
    end
  end

  defp handle_authentication_flow(
         server_handshake(major_ver: major_ver, minor_ver: minor_ver),
         _password,
         state
       )
       when major_ver != @major_ver or
              (major_ver == 0 and (minor_ver < @minor_ver_min or minor_ver > @minor_ver)) do
    exc =
      Error.client_connection_error(
        "the server requested an unsupported version of the protocol #{major_ver}.#{minor_ver}"
      )

    {:disconnect, exc, state}
  end

  defp handle_authentication_flow(
         server_handshake(),
         password,
         state
       ) do
    with {:ok, {message, buffer}} <- receive_message(state) do
      handle_authentication_flow(message, password, %State{state | buffer: buffer})
    end
  end

  defp handle_authentication_flow(authentication_ok(), _password, state) do
    {:ok, state}
  end

  defp handle_authentication_flow(authentication_sasl(), nil, %State{} = state) do
    exc =
      Error.authentication_error(
        "password should be provided for #{inspect(state.user)} authentication authentication"
      )

    {:disconnect, exc, state}
  end

  defp handle_authentication_flow(
         authentication_sasl(methods: [@scram_sha_256]),
         password,
         %State{} = state
       ) do
    {server_first, cf_data} = EdgeDB.SCRAM.handle_client_first(state.user, password)

    message = authentication_sasl_initial_response(method: @scram_sha_256, sasl_data: cf_data)

    with :ok <- send_message(message, state),
         {:ok, {message, buffer}} <- receive_message(state) do
      handle_sasl_authentication_flow(message, server_first, %State{state | buffer: buffer})
    end
  end

  defp handle_authentication_flow(error_response() = message, _password, state) do
    handle_error_response(message, state)
  end

  defp handle_sasl_authentication_flow(
         authentication_sasl_continue(sasl_data: data),
         %SCRAM.ServerFirst{} = server_first,
         state
       ) do
    with {:ok, {server_final, client_final_data}} <-
           EdgeDB.SCRAM.handle_server_first(server_first, data),
         :ok <- send_message(authentication_sasl_response(sasl_data: client_final_data), state),
         {:ok, {message, buffer}} <- receive_message(state) do
      handle_sasl_authentication_flow(message, server_final, %State{state | buffer: buffer})
    else
      {:error, reason} ->
        exc =
          Error.authentication_error("unable to continue SASL authentication: #{inspect(reason)}")

        {:disconnect, exc, state}

      {:disconnect, _exc, _state} = disconnect ->
        disconnect
    end
  end

  defp handle_sasl_authentication_flow(
         authentication_sasl_final(sasl_data: data),
         %SCRAM.ServerFinal{} = server_final,
         state
       ) do
    with :ok <- EdgeDB.SCRAM.handle_server_final(server_final, data),
         {:ok, {message, buffer}} <- receive_message(state) do
      handle_sasl_authentication_flow(message, %State{state | buffer: buffer})
    else
      {:error, reason} ->
        exc =
          Error.authentication_error("unable to complete SASL authentication: #{inspect(reason)}")

        {:disconnect, exc, state}

      {:disconnect, _exc, _state} = disconnect ->
        disconnect
    end
  end

  defp handle_sasl_authentication_flow(error_response() = message, _scram_data, state) do
    handle_error_response(message, state)
  end

  defp handle_sasl_authentication_flow(authentication_ok(), state) do
    {:ok, state}
  end

  defp handle_sasl_authentication_flow(error_response() = message, state) do
    handle_error_response(message, state)
  end

  defp wait_for_server_ready(state) do
    with {:ok, {message, buffer}} <- receive_message(state) do
      handle_server_ready_flow(message, %State{state | buffer: buffer})
    end
  end

  defp handle_server_ready_flow(server_key_data(data: data), state) do
    wait_for_server_ready(%State{state | server_key_data: data})
  end

  # TODO: maybe use it somehow, but right now just ignore it
  defp handle_server_ready_flow(parameter_status(), state) do
    wait_for_server_ready(state)
  end

  defp handle_server_ready_flow(ready_for_command(transaction_state: transaction_state), state) do
    {:ok, %State{state | server_state: transaction_state}}
  end

  defp handle_server_ready_flow(error_response() = message, state) do
    handle_error_response(message, state)
  end

  defp prepare_query(%EdgeDB.Query{} = query, opts, state) do
    message =
      prepare(
        headers: opts,
        io_format: query.io_format,
        expected_cardinality: query.cardinality,
        command: query.statement
      )

    with :ok <- send_messages([message, flush()], state),
         {:ok, {message, buffer}} <- receive_message(state) do
      handle_prepare_query_flow(query, message, %State{state | buffer: buffer})
    end
  end

  defp handle_prepare_query_flow(
         %EdgeDB.Query{cardinality: :one},
         prepare_complete(cardinality: :no_result),
         state
       ) do
    exc =
      Error.cardinality_violation_error(
        "cann't execute query since expected single result and query doesn't return any data"
      )

    {:disconnect, exc, state}
  end

  defp handle_prepare_query_flow(
         query,
         prepare_complete(
           input_typedesc_id: in_id,
           output_typedesc_id: out_id
         ),
         %State{queries_cache: qc, codecs_storage: cs} = state
       ) do
    input_codec = Codecs.Storage.get(cs, in_id)
    output_codec = Codecs.Storage.get(cs, out_id)

    if is_nil(input_codec) or is_nil(output_codec) do
      describe_codecs_from_query(query, state)
    else
      query = save_query_with_codecs_in_cache(qc, query, input_codec, output_codec)

      {:ok, query, state}
    end
  end

  defp handle_prepare_query_flow(
         %EdgeDB.Query{cardinality: :one},
         command_data_description(result_cardinality: :no_result),
         state
       ) do
    exc =
      Error.cardinality_violation_error(
        "cann't execute query since expected single result and query doesn't return any data"
      )

    {:disconnect, exc, state}
  end

  defp handle_prepare_query_flow(
         query,
         command_data_description() = message,
         %State{codecs_storage: cs, queries_cache: qc} = state
       ) do
    {input_codec, output_codec} = parse_description_message(message, cs)

    query = save_query_with_codecs_in_cache(qc, query, input_codec, output_codec)

    {:ok, query, state}
  end

  defp handle_prepare_query_flow(_query, error_response() = message, state) do
    handle_error_response(message, state)
  end

  defp optimistic_execute_query(%EdgeDB.Query{} = query, params, opts, state) do
    message =
      optimistic_execute(
        headers: opts,
        io_format: query.io_format,
        expected_cardinality: query.cardinality,
        command_text: query.statement,
        input_typedesc_id: query.input_codec.type_id,
        output_typedesc_id: query.output_codec.type_id,
        arguments: params
      )

    with :ok <- send_messages([message, sync()], state),
         {:ok, {message, buffer}} <- receive_message(state) do
      handle_optimistic_execute_flow(
        query,
        EdgeDB.Result.new(query.cardinality),
        message,
        %State{state | buffer: buffer}
      )
    end
  end

  defp handle_optimistic_execute_flow(
         %EdgeDB.Query{cardinality: :one},
         _result,
         command_data_description(result_cardinality: :no_result),
         state
       ) do
    exc =
      Error.cardinality_violation_error(
        "cann't execute query since expected single result and query doesn't return any data"
      )

    {:disconnect, exc, state}
  end

  defp handle_optimistic_execute_flow(
         query,
         _result,
         command_data_description() = message,
         %State{codecs_storage: cs, queries_cache: qc} = state
       ) do
    {input_codec, output_codec} = parse_description_message(message, cs)
    query = save_query_with_codecs_in_cache(qc, query, input_codec, output_codec)
    reencoded_params = DBConnection.Query.encode(query, query.params, [])
    execute_query(query, reencoded_params, state)
  end

  defp handle_optimistic_execute_flow(query, result, data() = message, state) do
    handle_execute_flow(query, result, message, state)
  end

  defp handle_optimistic_execute_flow(_query, _result, error_response() = message, state) do
    handle_error_response(message, state)
  end

  defp execute_query(%EdgeDB.Query{} = query, params, state) do
    message = execute(arguments: params)

    with :ok <- send_messages([message, sync()], state),
         {:ok, {message, buffer}} <- receive_message(state) do
      handle_execute_flow(
        query,
        EdgeDB.Result.new(query.cardinality),
        message,
        %State{state | buffer: buffer}
      )
    end
  end

  defp handle_execute_flow(
         %EdgeDB.Query{} = query,
         result,
         data(data: [data_element(data: data)]),
         state
       ) do
    result = EdgeDB.Result.add_encoded_data(result, data)

    with {:ok, {message, buffer}} <- receive_message(state) do
      handle_execute_flow(query, result, message, %State{state | buffer: buffer})
    end
  end

  defp handle_execute_flow(query, result, command_complete(status: status), state) do
    with {:ok, state} <- wait_for_server_ready(state) do
      {:ok, query, %EdgeDB.Result{result | statement: status}, state}
    end
  end

  defp handle_execute_flow(_query, _result, error_response() = message, state) do
    handle_error_response(message, state)
  end

  defp describe_codecs_from_query(query, state) do
    message = describe_statement(aspect: :data_description)

    with :ok <- send_messages([message, flush()], state),
         {:ok, {message, buffer}} <- receive_message(state) do
      handle_prepare_query_flow(query, message, %State{state | buffer: buffer})
    end
  end

  defp parse_description_message(
         command_data_description(
           input_typedesc_id: input_typedesc_id,
           input_typedesc: input_typedesc,
           output_typedesc_id: output_typedesc_id,
           output_typedesc: output_typedesc
         ),
         codecs_storage
       ) do
    input_codec =
      Codecs.Storage.get_or_create(codecs_storage, input_typedesc_id, fn ->
        Codecs.from_type_description(codecs_storage, input_typedesc)
      end)

    output_codec =
      Codecs.Storage.get_or_create(codecs_storage, output_typedesc_id, fn ->
        Codecs.from_type_description(codecs_storage, output_typedesc)
      end)

    {input_codec, output_codec}
  end

  defp close_prepared_query(query, %State{} = state) do
    QueriesCache.clear(state.queries_cache, query)
    {:ok, EdgeDB.Result.closed_query(), state}
  end

  defp start_transaction(opts, state) do
    opts
    |> QueryBuilder.start_transaction_statement()
    |> execute_script_query([allow_capabilities: :all], state)
  end

  defp commit_transaction(state) do
    statement = QueryBuilder.commit_transaction_statement()
    execute_script_query(statement, [allow_capabilities: :all], state)
  end

  defp rollback_transaction(state) do
    statement = QueryBuilder.rollback_transaction_statement()
    execute_script_query(statement, [allow_capabilities: :all], state)
  end

  defp execute_script_query(statement, headers, state) do
    message = execute_script(headers: headers, script: statement)

    with :ok <- send_message(message, state),
         {:ok, {message, buffer}} <- receive_message(state) do
      handle_execute_script_flow(message, %State{state | buffer: buffer})
    end
  end

  defp handle_execute_script_flow(command_complete(status: status), state) do
    result = %EdgeDB.Result{
      cardinality: :no_result,
      statement: status
    }

    with {:ok, state} <- wait_for_server_ready(state) do
      {:ok, result, state}
    end
  end

  defp handle_execute_script_flow(error_response() = message, state) do
    handle_error_response(message, state)
  end

  defp handle_error_response(
         error_response(
           error_code: code,
           message: message,
           attributes: attributes
         ),
         state
       ) do
    exc = Error.exception(message, code: code, attributes: Enum.into(attributes, %{}))
    {:disconnect, exc, state}
  end

  defp handle_log_message(log_message(severity: severity, text: text), state) do
    Logger.log(severity, text)
    state
  end

  defp save_query_with_codecs_in_cache(
         queries_cache,
         query,
         input_codec,
         output_codec
       ) do
    query = %EdgeDB.Query{
      query
      | input_codec: input_codec,
        output_codec: output_codec
    }

    QueriesCache.add(queries_cache, query)

    query
  end

  defp send_message(message, state) do
    message
    |> EdgeDB.Protocol.encode_message()
    |> send_data_into_socket(state)
  end

  defp send_messages(messages, state) when is_list(messages) do
    messages
    |> Enum.map(&EdgeDB.Protocol.encode_message/1)
    |> send_data_into_socket(state)
  end

  defp receive_message(state) do
    case EdgeDB.Protocol.decode_message(state.buffer) do
      {:ok, {log_message() = message, buffer}} ->
        state = handle_log_message(message, %State{state | buffer: buffer})
        receive_message(state)

      {:ok, _res} = result ->
        result

      {:error, {:not_enough_size, size}} ->
        receive_message_data_from_socket(size, state)
    end
  end

  defp receive_message_data_from_socket(required_data_size, state) do
    case :ssl.recv(state.socket, min(required_data_size, @max_packet_size), state.timeout) do
      {:ok, data} ->
        receive_message(%State{state | buffer: state.buffer <> data})

      {:error, reason} ->
        exc = exception_from_socket_error(reason)
        {:disconnect, exc, state}
    end
  end

  defp send_data_into_socket(data, %State{socket: socket} = state) do
    case :ssl.send(socket, data) do
      :ok ->
        :ok

      {:error, reason} ->
        err = exception_from_socket_error(reason)
        {:disconnect, err, state}
    end
  end

  defp exception_from_socket_error(:closed) do
    Error.client_connection_closed_error("connection has been closed")
  end

  defp exception_from_socket_error(:etimedout) do
    Error.client_connection_timeout_error("exceeded timeout")
  end

  defp exception_from_socket_error(reason) do
    Error.client_connection_error(
      "unexpected error while receiving data from socket: #{inspect(reason)}"
    )
  end

  defp status(%State{server_state: :not_in_transaction}) do
    :idle
  end

  defp status(%State{server_state: :in_transaction}) do
    :transaction
  end

  defp status(%State{server_state: :in_failed_transaction}) do
    :error
  end
end

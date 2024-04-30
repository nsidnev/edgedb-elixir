defmodule EdgeDB.Connection.Config do
  @moduledoc false

  alias EdgeDB.Connection.Config.{
    Cloud,
    Credentials,
    DSN,
    Validation
  }

  @default_host "localhost"
  @default_port 5656
  @default_database "edgedb"
  @default_branch "__default__"
  @default_user "edgedb"
  @default_timeout 15_000

  @dsn_regex ~r"^[a-z]+://"
  @instance_name_regex ~r/^(\w(?:-?\w)*)$/
  @cloud_instance_name_regex ~r|^([A-Za-z0-9](?:-?[A-Za-z0-9])*)/([A-Za-z0-9](?:-?[A-Za-z0-9])*)$|

  @file_module Application.compile_env(:edgedb, :file_module, File)
  @path_module Application.compile_env(:edgedb, :path_module, Path)
  @system_module Application.compile_env(:edgedb, :system_module, System)

  @spec connect_opts(Keyword.t()) :: Keyword.t()
  def connect_opts(opts) do
    {dsn, instance_name} =
      with {:ok, dsn} <- Keyword.fetch(opts, :dsn),
           true <- Regex.match?(@dsn_regex, dsn) do
        {dsn, nil}
      else
        :error ->
          {nil, nil}

        false ->
          {nil, opts[:dsn]}
      end

    explicit_opts = Keyword.merge(opts, dsn: dsn, instance_name: instance_name)

    resolved_opts =
      with {:cont, resolved_opts} <- resolve_explicit_opts(explicit_opts),
           {:cont, resolved_opts} <- resolve_config_opts(resolved_opts),
           {:cont, resolved_opts} <- resolve_environment_opts(resolved_opts) do
        resolve_project_opts(resolved_opts)
      else
        {:halt, resolved_opts} ->
          resolved_opts
      end

    resolved_opts = transform_opts(resolved_opts)
    Keyword.merge(opts, resolved_opts)
  end

  defp transform_opts(opts) do
    tls_security = opts[:tls_security] || :default
    security = opts[:security] || :default

    if opts[:tls_ca] && opts[:tls_ca_file] do
      raise EdgeDB.ClientConnectionError.new("tls_ca and tls_ca_file are mutually exclusive")
    end

    tls_security =
      cond do
        security == :default and tls_security != :default ->
          tls_security

        security == :insecure_dev_mode and tls_security == :default ->
          :insecure

        security == :strict and tls_security == :default ->
          :strict

        security == :strict and tls_security in [:no_host_verification, :insecure] ->
          raise RuntimeError,
            message:
              "EDGEDB_CLIENT_SECURITY=#{security} but tls_security=#{tls_security}, " <>
                "tls_security must be set to strict when EDGEDB_CLIENT_SECURITY is strict"

        tls_security != :default ->
          tls_security

        not is_nil(opts[:tls_ca]) or not is_nil(opts[:tls_ca_file]) ->
          :no_host_verification

        true ->
          :strict
      end

    opts
    |> Keyword.put_new_lazy(:address, fn ->
      {opts[:host] || @default_host, opts[:port] || @default_port}
    end)
    |> Keyword.update(:database, opts[:branch] || @default_database, fn database ->
      database || opts[:branch] || @default_database
    end)
    |> Keyword.update(:branch, opts[:database] || @default_branch, fn branch ->
      branch || opts[:database] || @default_branch
    end)
    |> Keyword.update(:user, @default_user, fn user ->
      user || @default_user
    end)
    |> Keyword.put_new_lazy(:tls_ca, fn ->
      if tls_ca_file = opts[:tls_ca_file] do
        @file_module.read!(tls_ca_file)
      else
        nil
      end
    end)
    |> Keyword.put(:tls_security, tls_security)
    |> Keyword.put_new(:timeout, @default_timeout)
  end

  defp resolve_explicit_opts(opts) do
    case resolve_opts([], opts) do
      {resolved_opts, 0} ->
        {:cont, resolved_opts}

      {resolved_opts, 1} ->
        {:halt, resolved_opts}

      _other ->
        raise EdgeDB.ClientConnectionError.new(
                "can not have more than one of the following connection options: " <>
                  ":dsn, :credentials, :credentials_file or :host/:port"
              )
    end
  end

  defp resolve_config_opts(resolved_opts) do
    case resolve_opts(resolved_opts, config_opts()) do
      {resolved_opts, 0} ->
        {:cont, resolved_opts}

      {resolved_opts, 1} ->
        {:halt, resolved_opts}

      _other ->
        raise EdgeDB.ClientConnectionError.new(
                "can not have more than one of the following connection options in config: " <>
                  ":dsn, :credentials_file :host/:port"
              )
    end
  end

  defp resolve_environment_opts(resolved_opts) do
    case resolve_opts(resolved_opts, environment_opts()) do
      {resolved_opts, 0} ->
        {:cont, resolved_opts}

      {resolved_opts, 1} ->
        {:halt, resolved_opts}

      _other ->
        raise EdgeDB.ClientConnectionError.new(
                "can not have more than one of the following connection environment variables:" <>
                  ~s("EDGEDB_DSN", "EDGEDB_INSTANCE", ) <>
                  ~s("EDGEDB_CREDENTIALS_FILE" or "EDGEDB_HOST"/"EDGEDB_PORT")
              )
    end
  end

  defp resolve_project_opts(resolved_opts) do
    project_dir = find_edgedb_project_dir()
    stash_dir = Credentials.stash_dir(project_dir)

    if not @file_module.exists?(stash_dir) do
      raise EdgeDB.ClientConnectionError.new(
              ~s(found "edgedb.toml" but the project is not initialized, run "edgedb project init")
            )
    end

    instance_name =
      [stash_dir, "instance-name"]
      |> @path_module.join()
      |> @file_module.read!()
      |> String.trim()

    project_opts = [instance_name: instance_name]

    cloud_profile_path = @path_module.join(stash_dir, "cloud-profile")

    project_opts =
      cond do
        not is_nil(resolved_opts[:cloud_profile]) ->
          project_opts

        @file_module.exists?(cloud_profile_path) ->
          cloud_profile =
            cloud_profile_path
            |> @file_module.read!()
            |> String.trim()

          Keyword.merge(project_opts, cloud_profile: cloud_profile)

        true ->
          project_opts
      end

    database_path = @path_module.join(stash_dir, "database")

    project_opts =
      if @file_module.exists?(database_path) do
        database = @file_module.read!(database_path)
        Keyword.merge(project_opts, database: database)
      else
        project_opts
      end

    branch_path = @path_module.join(stash_dir, "branch")

    project_opts =
      if @file_module.exists?(branch_path) do
        branch = @file_module.read!(branch_path)
        Keyword.merge(project_opts, branch: branch)
      else
        project_opts
      end

    {resolved_opts, _compounds} = resolve_opts(resolved_opts, project_opts)

    resolved_opts
  end

  defp resolve_opts(resolved_opts, opts) do
    resolved_opts =
      resolved_opts
      |> Keyword.put_new_lazy(:user, fn ->
        Validation.validate_user(opts[:user])
      end)
      |> Keyword.put_new(:password, opts[:password])
      |> Keyword.put_new_lazy(:tls_ca_file, fn ->
        Validation.validate_tls_ca_file(opts[:tls_ca_file])
      end)
      |> Keyword.put_new_lazy(:tls_security, fn ->
        Validation.validate_tls_security(opts[:tls_security])
      end)
      |> Keyword.put_new_lazy(:tls_server_name, fn ->
        Validation.validate_tls_server_name(opts[:tls_server_name])
      end)
      |> Keyword.put_new_lazy(:server_settings, fn ->
        Validation.validate_server_settings(opts[:server_settings])
      end)
      |> Enum.reject(fn {_key, value} ->
        is_nil(value)
      end)

    if not is_nil(opts[:database]) and not is_nil(opts[:branch]) do
      raise EdgeDB.ClientConnectionError.new(":database and :branch keys are mutually exclusive")
    end

    resolved_opts =
      if not is_nil(opts[:database]) and is_nil(resolved_opts[:branch]) do
        Keyword.put_new_lazy(resolved_opts, :database, fn ->
          Validation.validate_database(opts[:database])
        end)
      else
        resolved_opts
      end

    resolved_opts =
      if not is_nil(opts[:branch]) and is_nil(resolved_opts[:database]) do
        Keyword.put_new_lazy(resolved_opts, :branch, fn ->
          Validation.validate_database(opts[:branch])
        end)
      else
        resolved_opts
      end

    opts = Keyword.drop(opts, [:database, :branch])

    compound_params_count =
      [
        opts[:dsn],
        opts[:instance_name],
        opts[:credentials],
        opts[:credentials_file],
        opts[:host] || opts[:port]
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.count()

    resolved_opts =
      cond do
        compound_params_count == 1 and not is_nil(opts[:dsn] || opts[:host] || opts[:port]) ->
          resolved_opts =
            if port = opts[:port] do
              Keyword.put_new(resolved_opts, :port, Validation.validate_port(port))
            else
              resolved_opts
            end

          dsn =
            if dsn = opts[:dsn] do
              dsn
            else
              "edgedb://#{parse_host(opts[:host])}"
            end

          DSN.parse_dsn_into_opts(dsn, resolved_opts)

        compound_params_count == 1 ->
          credentials = parse_credentials(opts, resolved_opts)
          safe_credentials = Keyword.drop(credentials, [:database, :branch])
          resolved_opts = Keyword.merge(safe_credentials, resolved_opts)

          resolved_opts =
            if not is_nil(credentials[:database]) and is_nil(resolved_opts[:branch]) do
              Keyword.put_new(
                resolved_opts,
                :database,
                Validation.validate_database(credentials[:database])
              )
            else
              resolved_opts
            end

          if not is_nil(credentials[:branch]) and is_nil(resolved_opts[:database]) do
            Keyword.put_new(
              resolved_opts,
              :branch,
              Validation.validate_branch(credentials[:branch])
            )
          else
            resolved_opts
          end

        true ->
          resolved_opts
      end

    resolved_opts = Keyword.merge(opts, resolved_opts)
    {resolved_opts, compound_params_count}
  end

  defp parse_credentials(opts, resolved_opts) do
    cond do
      credentials_file = opts[:credentials_file] ->
        Credentials.read_creadentials(credentials_file)

      credentials = opts[:credentials] ->
        Credentials.parse_credentials(credentials)

      Regex.match?(@instance_name_regex, opts[:instance_name] || "") ->
        opts[:instance_name]
        |> Credentials.get_credentials_path()
        |> Credentials.read_creadentials()

      Regex.match?(@cloud_instance_name_regex, opts[:instance_name] || "") ->
        [org_slug, instance_name] = String.split(opts[:instance_name], "/")
        secret_key = opts[:secret_key] || resolved_opts[:secret_key]

        cloud_profile =
          opts[:cloud_profile] || resolved_opts[:cloud_profile] ||
            from_env("EDGEDB_CLOUD_PROFILE")

        Cloud.parse_cloud_credentials(org_slug, instance_name, secret_key, cloud_profile)

      true ->
        raise RuntimeError,
          message:
            "invalid DSN or instance name: " <>
              "#{inspect(opts[:instance_name])} doesn't match valid local or cloud instance regex"
    end
  end

  defp config_opts do
    clear_opts(
      dsn: from_config(:dsn),
      instance_name: from_config(:instance_name),
      credentials: from_config(:credentials),
      credentials_file: from_config(:credentials_file),
      host: from_config(:host),
      port: from_config(:port),
      database: from_config(:database),
      branch: from_config(:branch),
      user: from_config(:user),
      password: from_config(:password),
      secret_key: from_config(:secret_key),
      cloud_profile: from_config(:cloud_profile),
      tls_ca: from_config(:tls_ca),
      tls_ca_file: from_config(:tls_ca_file),
      tls_security: from_config(:tls_security),
      tls_server_name: from_config(:tls_server_name),
      timeout: from_config(:timeout),
      command_timeout: from_config(:command_timeout),
      wait_for_available: from_config(:wait_for_available),
      server_settings: from_config(:server_settings),
      tcp: from_config(:tcp),
      ssl: from_config(:ssl),
      transaction: from_config(:transaction),
      retry: from_config(:retry),
      connection: from_config(:connection),
      pool: from_config(:pool),
      client_state: from_config(:client_state)
    )
  end

  defp environment_opts do
    port =
      case from_env("EDGEDB_PORT") do
        "tcp" <> _term ->
          nil

        env_var ->
          env_var
      end

    security =
      "EDGEDB_CLIENT_SECURITY"
      |> from_env()
      |> Validation.validate_security()

    clear_opts(
      dsn: from_env("EDGEDB_DSN"),
      instance_name: from_env("EDGEDB_INSTANCE"),
      credentials_file: from_env("EDGEDB_CREDENTIALS_FILE"),
      host: from_env("EDGEDB_HOST"),
      port: port,
      database: from_env("EDGEDB_DATABASE"),
      branch: from_env("EDGEDB_BRANCH"),
      user: from_env("EDGEDB_USER"),
      password: from_env("EDGEDB_PASSWORD"),
      secret_key: from_env("EDGEDB_SECRET_KEY"),
      cloud_profile: from_env("EDGEDB_CLOUD_PROFILE"),
      tls_ca: from_env("EDGEDB_TLS_CA"),
      tls_ca_file: from_env("EDGEDB_TLS_CA_FILE"),
      tls_security: from_env("EDGEDB_CLIENT_TLS_SECURITY"),
      tls_server_name: from_env("EDGEDB_TLS_SERVER_NAME"),
      security: security
    )
  end

  defp clear_opts(opts) do
    Enum.reduce(opts, [], fn
      {_key, nil}, opts ->
        opts

      {key, value}, opts ->
        Keyword.put(opts, key, value)
    end)
  end

  defp from_config(name) do
    Application.get_env(:edgedb, name)
  end

  defp from_env(name) do
    @system_module.get_env(name)
  end

  defp find_edgedb_project_dir do
    dir = @file_module.cwd!()
    find_edgedb_project_dir(dir)
  end

  defp find_edgedb_project_dir(dir) do
    dev = @file_module.stat!(dir).major_device
    project_file = @path_module.join(dir, "edgedb.toml")

    if @file_module.exists?(project_file) do
      dir
    else
      parent = @path_module.dirname(dir)

      if parent == dir do
        raise EdgeDB.ClientConnectionError.new(
                ~s(no "edgedb.toml" found and no connection options specified)
              )
      end

      parent_dev = @file_module.stat!(parent).major_device

      if parent_dev != dev do
        raise EdgeDB.ClientConnectionError.new(
                ~s(no "edgedb.toml" found and no connection options specified) <>
                  ~s(stopped searching for "edgedb.toml" at file system boundary #{inspect(dir)})
              )
      end

      find_edgedb_project_dir(parent)
    end
  end

  defp parse_host(nil) do
    ""
  end

  defp parse_host(host) do
    host =
      if String.contains?(host, ":") do
        "[#{host}]"
      else
        host
      end

    Validation.validate_host(host)
  end
end

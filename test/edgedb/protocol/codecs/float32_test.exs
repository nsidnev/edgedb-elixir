defmodule Tests.EdgeDB.Protocol.Codecs.Flaot32Test do
  use Tests.Support.EdgeDBCase

  setup :edgedb_connection

  test "decoding std::float32 value", %{conn: conn} do
    value = 0.5
    assert ^value = EdgeDB.query_single!(conn, "select <float32>0.5")
  end

  test "decoding NaN as std::float32 value", %{conn: conn} do
    value = :nan
    assert ^value = EdgeDB.query_single!(conn, "select <float32>'NaN'")
  end

  test "decoding infinity as std::float32 value", %{conn: conn} do
    value = :infinity
    assert ^value = EdgeDB.query_single!(conn, "select <float32>'inf'")
  end

  test "decoding -infinity as std::float32 value", %{conn: conn} do
    value = :negative_infinity
    assert ^value = EdgeDB.query_single!(conn, "select <float32>'-inf'")
  end

  test "encoding std::float32 argument", %{conn: conn} do
    value = 1.0
    assert ^value = EdgeDB.query_single!(conn, "select <float32>$0", [value])
  end

  test "encoding NaN as std::float32 argument", %{conn: conn} do
    value = :nan
    assert ^value = EdgeDB.query_single!(conn, "select <float32>$0", [value])
  end

  test "encoding infinity as std::float32 argument", %{conn: conn} do
    value = :infinity
    assert ^value = EdgeDB.query_single!(conn, "select <float32>$0", [value])
  end

  test "encoding -infinity as std::float32 argument", %{conn: conn} do
    value = :negative_infinity
    assert ^value = EdgeDB.query_single!(conn, "select <float32>$0", [value])
  end

  test "error when passing non-number as std::float32 argument", %{conn: conn} do
    value = "something"

    exc =
      assert_raise EdgeDB.Error, fn ->
        EdgeDB.query_single!(conn, "select <float32>$0", [value])
      end

    assert exc ==
             EdgeDB.Error.invalid_argument_error(
               "value can not be encoded as std::float32: #{inspect(value)}"
             )
  end
end

defmodule EdgeDB.Protocol.Types.ShapeElement do
  use EdgeDB.Protocol.Type

  alias EdgeDB.Protocol.DataTypes

  @field_is_implicit Bitwise.bsl(1, 0)
  @field_is_link_property Bitwise.bsl(1, 1)
  @field_is_link Bitwise.bsl(1, 2)

  deftype(
    name: :shape_element,
    encode?: false,
    fields: [
      flags: DataTypes.UInt8.t(),
      name: DataTypes.String.t(),
      type_pos: DataTypes.UInt16.t()
    ]
  )

  @spec link?(t()) :: boolean()
  def link?(shape_element(flags: flags)) do
    Bitwise.band(flags, @field_is_link) != 0
  end

  @spec link_property?(t()) :: boolean()
  def link_property?(shape_element(flags: flags)) do
    Bitwise.band(flags, @field_is_link_property) != 0
  end

  @spec implicit?(t()) :: boolean()
  def implicit?(shape_element(flags: flags)) do
    Bitwise.band(flags, @field_is_implicit) != 0
  end

  @spec decode(bitstring()) :: {t(), bitstring()}
  def decode(<<flags::uint8, rest::binary>>) do
    {name, rest} = DataTypes.String.decode(rest)
    {type_pos, rest} = DataTypes.UInt16.decode(rest)

    {shape_element(flags: flags, name: name, type_pos: type_pos), rest}
  end
end
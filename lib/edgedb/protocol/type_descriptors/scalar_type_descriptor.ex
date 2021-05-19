defmodule EdgeDB.Protocol.TypeDescriptors.ScalarTypeDescriptor do
  use EdgeDB.Protocol.TypeDescriptor

  alias EdgeDB.Protocol.Codecs

  deftypedescriptor(type: 3)

  defp parse_description(codecs, type_id, <<type_pos::uint16, rest::binary>>) do
    codec = codec_by_index(codecs, type_pos)
    {Codecs.Scalar.new(type_id, codec), rest}
  end

  defp consume_description(_storage, _id, <<_type_pos::uint16, rest::binary>>) do
    rest
  end
end

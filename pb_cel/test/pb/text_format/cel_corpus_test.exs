defmodule PB.TextFormat.CELCorpusTest do
  use ExUnit.Case, async: true

  # The CEL conformance fixtures are upstream `.textproto` files that
  # `buf convert` turned into the committed `.binpb` files. Decoding the text
  # with PB.TextFormat must give the same value as decoding the binary, and
  # printing that value must decode back to it.
  #
  # Packed google.protobuf.Any payloads are compared as messages rather than
  # bytes: buf always writes map entry keys, PB omits default ones, and both
  # encodings decode to the same message.

  alias PB.TestSupport.CELConformance
  alias PB.TestSupport.TestSchema

  for fixture <- CELConformance.fixtures() do
    @fixture fixture

    test "#{fixture.text} decodes like #{fixture.output}" do
      type = String.to_atom(@fixture.type)
      text = CELConformance.fixture_text(@fixture)

      assert {:ok, decoded} = PB.TextFormat.decode(text, TestSchema, type)
      assert unpack_any(decoded) == unpack_any(CELConformance.decode_fixture(@fixture))
    end

    test "#{fixture.output} prints and decodes back" do
      type = String.to_atom(@fixture.type)
      value = CELConformance.decode_fixture(@fixture)

      printed = PB.TextFormat.encode!(value, TestSchema, type)
      assert {:ok, decoded} = PB.TextFormat.decode(printed, TestSchema, type)
      assert unpack_any(decoded) == unpack_any(value)
    end
  end

  defp unpack_any(%{type_url: url, value: bytes} = any)
       when is_binary(url) and is_binary(bytes) do
    with {:ok, _prefix, name} <- PB.WellKnownTypes.Any.split_type_url(url),
         {:ok, packed} <- PB.decode(bytes, TestSchema, String.to_existing_atom(name)) do
      %{any | value: unpack_any(packed)}
    else
      _ -> any
    end
  end

  defp unpack_any(%_{} = struct), do: struct
  defp unpack_any(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, unpack_any(v)} end)
  defp unpack_any(list) when is_list(list), do: Enum.map(list, &unpack_any/1)
  defp unpack_any({tag, value}), do: {tag, unpack_any(value)}
  defp unpack_any(value), do: value
end

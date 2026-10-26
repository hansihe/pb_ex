defmodule PB.CEL.Syntax.ParserTest do
  # Parsed expressions through PB's cel.expr codecs; CEL's parser tests are
  # cel_ex's.
  use ExUnit.Case, async: true

  alias PB.CEL.ProtoCodec

  test "generated CEL proto codecs can round-trip parsed expressions" do
    parsed = CEL.parse!(~s|request.auth.claims["sub"].startsWith("x")|, location: "policy.cel")

    assert {:ok, iodata} = ProtoCodec.encode_parsed_expr(parsed)
    assert {:ok, decoded} = ProtoCodec.decode_parsed_expr(IO.iodata_to_binary(iodata))

    assert decoded.expr == parsed.expr
    assert decoded.source_info.location == "policy.cel"
    assert decoded.source_info.positions == parsed.source_info.positions

    macro_parsed = CEL.parse!("[1].all(x, x > 0)")
    assert {:ok, iodata} = ProtoCodec.encode_parsed_expr(macro_parsed)
    assert {:ok, decoded} = ProtoCodec.decode_parsed_expr(IO.iodata_to_binary(iodata))
    assert decoded == macro_parsed

    optional_parsed = CEL.parse!(~s|{?'x': optional.of(1), 'y': [?'z']}|)
    assert {:ok, iodata} = ProtoCodec.encode_parsed_expr(optional_parsed)
    assert {:ok, decoded} = ProtoCodec.decode_parsed_expr(IO.iodata_to_binary(iodata))
    assert decoded == optional_parsed
  end
end

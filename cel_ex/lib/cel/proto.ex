defmodule CEL.Proto do
  # Internal. Not part of the published API yet; may be exposed in a
  # later release. Original module doc retained below as reference.
  #
  # Types for CEL expression protos.
  #
  # The parser produces `cel.expr.ParsedExpr` values in the PB map shape.
  # Keeping these declarations in a small CEL-specific module gives the rest of
  # the implementation stable type names without exposing the full bundled
  # schema. Encoding and decoding them is the protobuf binding's job; see
  # `PB.CEL.ProtoCodec`.
  @moduledoc false

  @type parsed_expr :: map()
  @type checked_expr :: map()
  @type eval_state :: map()
  @type expr_value :: map()
  @type value :: map()

  @type expr :: map()
  @type source_info :: map()
  @type constant :: map()
  @type type :: map()
end

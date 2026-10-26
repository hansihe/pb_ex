defmodule PB.CEL.BundledSchema do
  @moduledoc false

  # Bundled schema for the CEL expression protos (`cel.expr.*`) and the
  # well-known types they import, used by `PB.CEL.ProtoCodec`.
  #
  # The path is relative to the project compiling this module, which is pb_cel
  # also when it is a dependency: Mix compiles a dependency in its own
  # directory.

  use PB.Schema, descriptor: "priv/cel.binpb"
end

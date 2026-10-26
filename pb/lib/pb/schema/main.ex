defmodule PB.Schema.Main do
  @moduledoc false

  # Bundled schema provider for PB's main descriptor set.
  #
  # This schema includes `google.protobuf.descriptor.proto` and the well-known
  # types, as used by PB itself.

  use PB.Schema,
    descriptor: "priv/main.binpb",
    with_schema: PB.Bootstrap.descriptor_schema()
end

defmodule PB.Validate.BundledSchema do
  @moduledoc false

  # Bundled schema for `buf/validate/validate.proto`, `descriptor.proto` and
  # the well-known types: the standard rule messages, whose predefined rules
  # `PB.Validate.Schema` reads from their options, and the `buf.validate`
  # extensions.
  #
  # The path is relative to the project compiling this module, which is
  # pb_validate also when it is a dependency: Mix compiles a dependency in its
  # own directory.

  use PB.Schema, descriptor: "priv/validate.binpb"
end

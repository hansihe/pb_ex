defmodule PB.TestSupport.ValidatedSchema do
  @moduledoc false

  # A schema module compiled with the project, as a library using pb_validate
  # would define one, rather than at test time.
  use PB.Schema,
    descriptor: "test/fixtures/schema/validate_structural.binpb",
    plugins: [PB.Validate]
end

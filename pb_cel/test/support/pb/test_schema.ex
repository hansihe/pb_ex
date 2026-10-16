defmodule PB.TestSupport.TestSchema do
  @moduledoc false

  # The CEL conformance messages.
  use PB.Schema, descriptor: "test/fixtures/schema/test.binpb"
end

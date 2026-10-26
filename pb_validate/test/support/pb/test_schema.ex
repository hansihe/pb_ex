defmodule PB.TestSupport.TestSchema do
  @moduledoc false

  # The protovalidate conformance harness messages.
  use PB.Schema, descriptor: "test/fixtures/schema/test.binpb"
end

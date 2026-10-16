defmodule PB.TestSupport.TestSchema do
  @moduledoc false

  use PB.Schema, descriptor: "test/fixtures/schema/test.binpb"
end

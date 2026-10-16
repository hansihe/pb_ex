defmodule PB.Validate.ConformanceTesteeTest do
  # The protovalidate conformance runner needs Go, so this covers how its testee
  # builds the schema for one case: a slice of an unvalidated base schema with
  # the rules compiled in.
  use ExUnit.Case, async: true

  alias PB.TestSupport.ProtovalidateConformance.Testee

  defp base_schema(path), do: path |> File.read!() |> PB.decode_descriptor_set!() |> PB.compile()

  test "compiles the rules of the case message's slice" do
    message = :"validate_custom_predefined.CustomPredefinedRules"
    base = base_schema("test/fixtures/schema/validate_custom_predefined.binpb")

    assert {:ok, schema} = Testee.compile_case_schema(base, message)
    assert schema.roots == [message]
    assert :ok = PB.Validate.validate(%{value: "good", count: 2}, schema, message)

    assert {:error, %PB.Validate.Error{violations: [%{rule_id: "string.not_bad"}]}} =
             PB.Validate.validate(%{value: "bad", count: 2}, schema, message)
  end

  test "reports rules that do not compile as an error" do
    message = :"validate_phase2_invalid.InvalidMessageCEL"
    base = base_schema("test/fixtures/schema/validate_phase2_invalid.binpb")

    assert {:error, reason} = Testee.compile_case_schema(base, message)
    assert is_binary(reason)
  end
end

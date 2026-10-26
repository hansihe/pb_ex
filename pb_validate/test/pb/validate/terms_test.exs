defmodule PB.Validate.TermsTest do
  # Validation accepts the message terms `PB.encode/4` does.
  use ExUnit.Case, async: true

  defmodule MessageCELTerm do
    defstruct value: nil
  end

  defp person_descriptor_set do
    %{
      file: [
        %{
          name: "test.proto",
          package: :test,
          syntax: :proto3,
          message_type: [
            %{
              name: :Person,
              field: [
                %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                %{
                  name: :phones,
                  number: 4,
                  type: :TYPE_MESSAGE,
                  label: :LABEL_REPEATED,
                  type_name: :"test.PhoneNumber"
                }
              ]
            },
            %{
              name: :PhoneNumber,
              field: [
                %{name: :number, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
              ]
            }
          ]
        }
      ]
    }
  end

  describe "message-name metadata" do
    test "validation accepts matching message-name metadata" do
      schema = PB.compile(person_descriptor_set(), plugins: [PB.Validate])

      assert :ok =
               PB.Validate.validate(
                 %{
                   __message_name__: :"test.Person",
                   name: "Alice"
                 },
                 schema,
                 :"test.Person"
               )
    end

    test "validation rejects mismatched message-name metadata" do
      schema = PB.compile(person_descriptor_set(), plugins: [PB.Validate])
      key = :__message_name__

      assert {:error, %PB.ValueError{} = error} =
               PB.Validate.validate(%{key => :"test.PhoneNumber"}, schema, :"test.Person")

      assert Exception.message(error) =~
               ~r/message name mismatch .*expected :"test.Person", got :"test.PhoneNumber"/
    end
  end

  describe "represented terms" do
    test "protovalidate validates represented root terms" do
      schema =
        "test/fixtures/schema/validate_phase2.binpb"
        |> File.read!()
        |> PB.decode_descriptor_set!()
        |> PB.compile(
          projections: [
            {:"validate_phase2.MessageCEL", struct: MessageCELTerm}
          ],
          plugins: [PB.Validate]
        )

      assert :ok =
               PB.Validate.validate(
                 %MessageCELTerm{value: "ok"},
                 schema,
                 :"validate_phase2.MessageCEL"
               )

      assert {:error, %PB.Validate.Error{violations: [violation]}} =
               PB.Validate.validate(
                 %MessageCELTerm{value: ""},
                 schema,
                 :"validate_phase2.MessageCEL"
               )

      assert violation.rule_id == "x"
      assert violation.message == "value must not be empty"
    end
  end
end

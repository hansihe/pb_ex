defmodule PB.CEL.RepresentationTest do
  use ExUnit.Case, async: true

  defmodule PersonTerm do
    defstruct name: nil, companion: nil
  end

  defmodule PetTerm do
    defstruct name: nil
  end

  defmodule FishTerm do
    defstruct species: nil
  end

  defp descriptor_set do
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
                  name: :pet,
                  number: 7,
                  type: :TYPE_MESSAGE,
                  label: :LABEL_OPTIONAL,
                  type_name: :"test.Pet",
                  oneof_index: 0
                },
                %{
                  name: :fish,
                  number: 8,
                  type: :TYPE_MESSAGE,
                  label: :LABEL_OPTIONAL,
                  type_name: :"test.Fish",
                  oneof_index: 0
                }
              ],
              oneof_decl: [%{name: :companion}]
            },
            %{
              name: :Pet,
              field: [
                %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
              ]
            },
            %{
              name: :Fish,
              field: [
                %{name: :species, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
              ]
            }
          ]
        }
      ]
    }
  end

  test "reads represented structs through a proto field view" do
    schema =
      PB.compile(descriptor_set(),
        projections: [
          {:"test.Person", struct: PersonTerm, oneofs: [companion: [representation: :identity]]},
          {:"test.Pet", struct: PetTerm},
          {:"test.Fish", struct: FishTerm}
        ]
      )

    person = %PersonTerm{
      name: "Alice",
      companion: %PetTerm{name: "Rex"}
    }

    assert CEL.eval!(
             "msg.name == 'Alice' && msg.pet.name == 'Rex' && has(msg.pet) && !has(msg.fish)",
             %{"msg" => person},
             CEL.Env.build(
               types: PB.CEL.types(schema),
               vars: %{"msg" => {:message, "test.Person"}}
             )
           ) == {:bool, true}
  end
end

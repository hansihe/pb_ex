defmodule PB.Codegen.TypespecTest do
  use ExUnit.Case

  alias PB.Codegen
  alias PB.Codegen.Typespec

  @descriptor_set %{
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
              %{name: :id, number: 2, type: :TYPE_INT32, label: :LABEL_OPTIONAL},
              %{
                name: :phones,
                number: 4,
                type: :TYPE_MESSAGE,
                label: :LABEL_REPEATED,
                type_name: :"test.PhoneNumber"
              },
              %{
                name: :role,
                number: 5,
                type: :TYPE_ENUM,
                label: :LABEL_OPTIONAL,
                type_name: :"test.Role"
              },
              %{
                name: :scores,
                number: 6,
                type: :TYPE_INT32,
                label: :LABEL_REPEATED
              },
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
              },
              %{
                name: :tags,
                number: 9,
                type: :TYPE_MESSAGE,
                label: :LABEL_REPEATED,
                type_name: :"test.Person.TagsEntry"
              }
            ],
            oneof_decl: [%{name: :companion}],
            nested_type: [
              %{
                name: :TagsEntry,
                options: %{map_entry: true},
                field: [
                  %{name: :key, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                  %{name: :value, number: 2, type: :TYPE_INT32, label: :LABEL_OPTIONAL}
                ]
              }
            ],
            enum_type: []
          },
          %{
            name: :PhoneNumber,
            field: [
              %{name: :number, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
            ]
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
        ],
        enum_type: [
          %{
            name: :Role,
            value: [
              %{name: :UNKNOWN, number: 0},
              %{name: :ADMIN, number: 1},
              %{name: :USER, number: 2}
            ]
          }
        ]
      }
    ]
  }

  @schema PB.compile(@descriptor_set)

  describe "Codegen.build/1" do
    test "builds registry for a single root" do
      ctx = build([:"test.Person"])

      assert Map.has_key?(ctx.registry, :"test.Person")
      assert Map.has_key?(ctx.registry, :"test.PhoneNumber")
      assert Map.has_key?(ctx.registry, :"test.Pet")
      assert Map.has_key?(ctx.registry, :"test.Fish")
      # Enum types are inlined.
      refute Map.has_key?(ctx.registry, :"test.Role")
      # Map entry types are inlined as :map_of.
      refute Map.has_key?(ctx.registry, :"test.Person.TagsEntry")
    end

    test "Person type def" do
      ctx = build([:"test.Person"])
      person = ctx.registry[:"test.Person"]

      assert person.kind == :map
      assert length(person.fields) == 7

      fields = Map.new(person.fields)
      assert fields[:name].type == %{kind: :scalar, spec: "String.t()"}
      assert fields[:id].type == %{kind: :scalar, spec: "integer()"}
      assert fields[:phones].type == %{kind: :list, inner: %{kind: :ref, id: :"test.PhoneNumber"}}
      assert fields[:role].type == %{kind: :enum, values: [:ADMIN, :UNKNOWN, :USER]}
      assert fields[:scores].type == %{kind: :list, inner: %{kind: :scalar, spec: "integer()"}}

      assert fields[:tags].type ==
               %{
                 kind: :map_of,
                 key: %{kind: :scalar, spec: "String.t()"},
                 value: %{kind: :scalar, spec: "integer()"}
               }

      companion = fields[:companion].type
      assert companion.kind == :oneof

      assert companion.variants == [
               {:pet, %{kind: :ref, id: :"test.Pet"}},
               {:fish, %{kind: :ref, id: :"test.Fish"}}
             ]
    end

    test "unknown root metadata is rejected" do
      schema = Map.put(@schema, :roots, [:"test.NonExistent"])

      assert_raise ArgumentError, ~r/unknown PB codegen root :"test.NonExistent"/, fn ->
        Codegen.build(schema)
      end
    end

    test "handles cycles" do
      schema =
        PB.compile(%{
          file: [
            %{
              name: "cycle.proto",
              package: :cycle,
              syntax: :proto3,
              message_type: [
                %{
                  name: :Node,
                  field: [
                    %{name: :value, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL},
                    %{
                      name: :next,
                      number: 2,
                      type: :TYPE_MESSAGE,
                      label: :LABEL_OPTIONAL,
                      type_name: :"cycle.Node"
                    }
                  ]
                }
              ]
            }
          ]
        })

      ctx = build([:"cycle.Node"], schema)
      node = ctx.registry[:"cycle.Node"]
      fields = Map.new(node.fields)
      assert fields[:next].type == %{kind: :ref, id: :"cycle.Node"}
    end
  end

  describe "name assignment" do
    test "assigns shortest unique suffixes" do
      ctx = build([:"test.Person"])

      assert ctx.names[:"test.Person"] == :person
      assert ctx.names[:"test.PhoneNumber"] == :phone_number
      assert ctx.names[:"test.Pet"] == :pet
      assert ctx.names[:"test.Fish"] == :fish
    end

    test "root names can be overridden explicitly" do
      ctx = build([{:"test.Person", :customer}, :"test.PhoneNumber"])

      assert ctx.names[:"test.Person"] == :customer
      assert ctx.names[:"test.PhoneNumber"] == :phone_number
    end

    test "disambiguates collisions with longer suffix" do
      schema =
        PB.compile(%{
          file: [
            %{
              name: "collide.proto",
              package: :a,
              syntax: :proto3,
              message_type: [
                %{
                  name: :Item,
                  field: [%{name: :x, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL}]
                }
              ]
            },
            %{
              name: "collide.proto",
              package: :b,
              syntax: :proto3,
              message_type: [
                %{
                  name: :Item,
                  field: [%{name: :y, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL}]
                }
              ]
            }
          ]
        })

      ctx = build([:"a.Item", :"b.Item"], schema)

      assert ctx.names[:"a.Item"] == :a_item
      assert ctx.names[:"b.Item"] == :b_item
    end
  end

  describe "Typespec.to_string/2" do
    test "renders message type" do
      ctx = build([:"test.Person"])

      str = Typespec.to_string(ctx, :"test.PhoneNumber")
      assert str == "%{\n  optional(:number) => String.t()\n}"
    end

    test "renders map with all field kinds" do
      ctx = build([:"test.Person"])
      str = Typespec.to_string(ctx, :"test.Person")

      assert str =~ "optional(:name) => String.t()"
      assert str =~ "optional(:id) => integer()"
      assert str =~ "optional(:phones) => list(phone_number())"
      assert str =~ "optional(:role) => :ADMIN | :UNKNOWN | :USER"
      assert str =~ "optional(:scores) => list(integer())"
      assert str =~ "optional(:tags) => %{String.t() => integer()}"
      assert str =~ "optional(:companion) => {:pet, pet()} | {:fish, fish()}"
    end
  end

  describe "Typespec.render_types/1" do
    test "returns topo-sorted type definitions" do
      ctx = build([:"test.Person"])
      types = Typespec.render_types(ctx)

      order = Enum.map(types, &elem(&1, 0))

      assert Enum.find_index(order, &(&1 == :fish)) < Enum.find_index(order, &(&1 == :person))
      assert Enum.find_index(order, &(&1 == :pet)) < Enum.find_index(order, &(&1 == :person))

      assert Enum.find_index(order, &(&1 == :phone_number)) <
               Enum.find_index(order, &(&1 == :person))

      person_def = Enum.find(types, fn {name, _} -> name == :person end)
      assert elem(person_def, 1) =~ "optional(:name) => String.t()"
    end
  end

  describe "Typespec.to_quoted/2" do
    test "returns valid quoted AST for a message" do
      ctx = build([:"test.Person"])

      ast = Typespec.to_quoted(ctx, :"test.PhoneNumber")
      str = Macro.to_string(ast)
      assert str == "%{optional(:number) => String.t()}"
    end
  end

  defp build(roots, schema \\ @schema) do
    schema
    |> PB.Schema.Transform.slice(roots: roots)
    |> Codegen.build()
  end
end

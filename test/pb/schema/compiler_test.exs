defmodule PB.Schema.CompilerTest do
  use ExUnit.Case, async: true

  @descriptor_set %{
    file: [
      %{
        name: "a.proto",
        package: :pkg,
        syntax: :proto3,
        message_type: [
          %{
            name: :Current,
            field: [%{name: :id, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL}],
            reserved_name: ["old_name", :older_name],
            reserved_range: [%{start: 5, end: 6}, %{start: 10, end: 20}]
          },
          %{name: :Plain, field: []}
        ]
      }
    ]
  }

  test "messages keep their reserved field names as strings" do
    schema = PB.compile(@descriptor_set)

    assert schema.messages[:"pkg.Current"].reserved_names == ["old_name", "older_name"]
    assert schema.messages[:"pkg.Plain"].reserved_names == []
  end

  test "messages keep their reserved number ranges, end exclusive" do
    schema = PB.compile(@descriptor_set)

    assert schema.messages[:"pkg.Current"].reserved_ranges == [
             %{start: 5, end: 6},
             %{start: 10, end: 20}
           ]

    assert schema.messages[:"pkg.Plain"].reserved_ranges == []
  end

  describe "enums" do
    @enum_set %{
      file: [
        %{
          name: "e.proto",
          package: :pkg,
          syntax: :proto2,
          enum_type: [
            %{name: :Color, value: [%{name: :RED, number: 1}, %{name: :GREEN, number: 2}]},
            %{
              name: :Aliased,
              options: %{allow_alias: true},
              value: [
                %{name: :ZERO, number: 0},
                %{name: :FIRST, number: 1},
                %{name: :SECOND, number: 1}
              ]
            }
          ],
          message_type: [
            %{
              name: :Holder,
              field: [
                %{
                  name: :color,
                  number: 1,
                  type: :TYPE_ENUM,
                  type_name: ".pkg.Color",
                  label: :LABEL_OPTIONAL
                },
                %{
                  name: :aliased,
                  number: 2,
                  type: :TYPE_ENUM,
                  type_name: ".pkg.Aliased",
                  label: :LABEL_OPTIONAL
                }
              ]
            }
          ]
        }
      ]
    }

    test "default to their first declared value" do
      schema = PB.compile(@enum_set)

      assert schema.enums[:"pkg.Color"].default == :RED
      assert schema.enums[:"pkg.Aliased"].default == :ZERO

      assert {:ok, %{color: :RED, aliased: :ZERO} = decoded} =
               PB.decode("", schema, :"pkg.Holder", defaults: true)

      assert {:ok, _bytes} = PB.encode(decoded, schema, :"pkg.Holder")
    end

    test "name an aliased number by its first declared name" do
      schema = PB.compile(@enum_set)

      assert schema.enums[:"pkg.Aliased"].by_number == %{0 => :ZERO, 1 => :FIRST}
      assert schema.enums[:"pkg.Aliased"].by_name == %{ZERO: 0, FIRST: 1, SECOND: 1}
      assert {:ok, %{aliased: :FIRST}} = PB.decode(<<16, 1>>, schema, :"pkg.Holder")
    end
  end
end

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
            reserved_name: ["old_name", :older_name]
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
end

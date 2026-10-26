defmodule PB.Runtime.FrontendTest do
  use ExUnit.Case, async: true

  alias PB.Runtime.Frontend

  defmodule Child do
    defstruct [:id]
  end

  @descriptor_set %{
    file: [
      %{
        name: "ext.proto",
        package: :ext,
        syntax: :proto2,
        message_type: [
          %{
            name: :Msg,
            field: [%{name: :id, number: 1, label: :LABEL_OPTIONAL, type: :TYPE_INT32}],
            extension_range: [%{start: 100, end: 200}]
          },
          %{
            name: :Child,
            field: [%{name: :id, number: 1, label: :LABEL_OPTIONAL, type: :TYPE_INT32}]
          }
        ],
        extension: [
          %{
            name: :child,
            number: 101,
            label: :LABEL_OPTIONAL,
            type: :TYPE_MESSAGE,
            type_name: ".ext.Child",
            extendee: ".ext.Msg"
          },
          %{
            name: :children,
            number: 102,
            label: :LABEL_REPEATED,
            type: :TYPE_MESSAGE,
            type_name: ".ext.Child",
            extendee: ".ext.Msg"
          },
          %{
            name: :number,
            number: 103,
            label: :LABEL_OPTIONAL,
            type: :TYPE_INT32,
            extendee: ".ext.Msg"
          }
        ]
      }
    ]
  }

  setup_all do
    schema = PB.compile(@descriptor_set, projections: [{:"ext.Child", struct: Child}])
    %{schema: schema, msg: schema.messages[:"ext.Msg"]}
  end

  @proto %{
    id: 1,
    __extensions__: %{
      "ext.child": %{id: 2},
      "ext.children": [%{id: 3}, %{id: 4}],
      "ext.number": 5
    }
  }

  defp native do
    %{
      id: 1,
      __extensions__: %{
        "ext.child": %Child{id: 2},
        "ext.children": [%Child{id: 3}, %Child{id: 4}],
        "ext.number": 5
      }
    }
  end

  test "from_proto projects message values held in extensions, as wire decode does", ctx do
    assert Frontend.from_proto(@proto, :"ext.Msg", ctx.msg, ctx.schema) == {:ok, native()}

    {:ok, wire} = PB.encode(native(), ctx.schema, :"ext.Msg")
    assert PB.decode(IO.iodata_to_binary(wire), ctx.schema, :"ext.Msg") == {:ok, native()}
  end

  test "to_proto converts projected extension values back", ctx do
    assert Frontend.to_proto(native(), :"ext.Msg", ctx.msg, ctx.schema) == {:ok, @proto}
  end
end

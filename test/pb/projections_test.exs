defmodule PB.ProjectionsTest do
  use ExUnit.Case, async: true

  @message :"proj.Msg"

  defmodule EventA do
    defstruct value: nil
  end

  defmodule EventB do
    defstruct value: nil
  end

  @adapter %PB.Adapter{
    to_proto: {__MODULE__, :to_proto},
    from_proto: {__MODULE__, :from_proto}
  }

  @other_adapter %PB.Adapter{
    to_proto: {__MODULE__, :other_to_proto},
    from_proto: {__MODULE__, :other_from_proto}
  }

  def to_proto(value), do: {:ok, value}
  def from_proto(value), do: {:ok, value}
  def other_to_proto(value), do: {:ok, value}
  def other_from_proto(value), do: {:ok, value}

  describe "entry parser" do
    test "rejects top-level non-list :projections" do
      assert_raise PB.OptionError, ~r/invalid value for :projections/, fn ->
        PB.compile(single_message_descriptor(), projections: %{})
      end
    end

    test "rejects entries that are not {fqn, opts} tuples" do
      assert_raise ArgumentError, ~r/expected PB projection entry/, fn ->
        PB.compile(single_message_descriptor(), projections: [:bad_entry])
      end
    end

    test "rejects non-atom fqn keys" do
      assert_raise ArgumentError, ~r/expected PB projection entry/, fn ->
        PB.compile(single_message_descriptor(),
          projections: [{"proj.Msg", struct: __MODULE__}]
        )
      end
    end

    test "rejects entries with non-keyword opts" do
      assert_raise ArgumentError, ~r/to be a keyword list/, fn ->
        PB.compile(single_message_descriptor(),
          projections: [{@message, [%{not: :keyword}]}]
        )
      end
    end

    test "rejects :struct combined with :unwrap" do
      assert_raise ArgumentError, ~r/cannot set both :struct and :unwrap/, fn ->
        PB.compile(single_message_descriptor(),
          projections: [{@message, struct: EventA, unwrap: :value}]
        )
      end
    end

    test "rejects aux-only entries with :preserved_unknown_fields and no kind" do
      assert_raise ArgumentError,
                   ~r/requires :struct or :unwrap when :preserved_unknown_fields or :extensions is set/,
                   fn ->
                     PB.compile(single_message_descriptor(),
                       projections: [{@message, preserved_unknown_fields: :reject}]
                     )
                   end
    end

    test "rejects aux-only entries with :extensions and no kind" do
      assert_raise ArgumentError,
                   ~r/requires :struct or :unwrap when :preserved_unknown_fields or :extensions is set/,
                   fn ->
                     PB.compile(single_message_descriptor(),
                       projections: [{@message, extensions: :reject}]
                     )
                   end
    end

    test "rejects malformed :oneofs (not a keyword list)" do
      assert_raise ArgumentError, ~r/expected PB :oneofs for .* to be a keyword list/, fn ->
        PB.compile(oneof_event_descriptor(),
          projections: [
            {:"proj.A", struct: EventA},
            {:"proj.B", struct: EventB},
            {:"proj.Event", oneofs: %{data: [representation: :identity]}}
          ]
        )
      end
    end

    test "rejects :oneofs entries missing :representation" do
      assert_raise ArgumentError, ~r/must set :representation/, fn ->
        PB.compile(oneof_event_descriptor(),
          projections: [
            {:"proj.A", struct: EventA},
            {:"proj.B", struct: EventB},
            {:"proj.Event", oneofs: [data: []]}
          ]
        )
      end
    end

    test "rejects :oneofs entries with unknown option keys" do
      assert_raise ArgumentError, ~r/unknown PB oneof representation option/, fn ->
        PB.compile(oneof_event_descriptor(),
          projections: [
            {:"proj.A", struct: EventA},
            {:"proj.B", struct: EventB},
            {:"proj.Event", oneofs: [data: [bogus: true]]}
          ]
        )
      end
    end

    test "rejects :oneofs entries with unsupported representation value" do
      assert_raise ArgumentError, ~r/invalid PB oneof representation/, fn ->
        PB.compile(oneof_event_descriptor(),
          projections: [
            {:"proj.A", struct: EventA},
            {:"proj.B", struct: EventB},
            {:"proj.Event", oneofs: [data: [representation: :wrapper]]}
          ]
        )
      end
    end
  end

  describe "merge conflicts" do
    test "duplicate :projections entries for the same fqn raise" do
      assert_raise ArgumentError, ~r/duplicate PB projection for :"proj.Msg"/, fn ->
        PB.compile(single_message_descriptor(),
          projections: [
            {@message, struct: EventA},
            {@message, adapter: @adapter}
          ]
        )
      end
    end

    test "duplicate :projections oneof entries for the same key raise" do
      assert_raise ArgumentError,
                   ~r/duplicate PB projection for {:"proj.Event", :data}/,
                   fn ->
                     PB.compile(oneof_event_descriptor(),
                       projections: [
                         {:"proj.A", struct: EventA},
                         {:"proj.B", struct: EventB},
                         {:"proj.Event",
                          oneofs: [
                            data: [representation: :identity],
                            data: [representation: :identity]
                          ]}
                       ]
                     )
                   end
    end

    test "adapter vs proto-source representation conflict surfaces both sources" do
      assert_raise ArgumentError,
                   ~r/conflicting PB projection for :"option_rep.Msg":.*proto-source.*compile-time :projections/s,
                   fn ->
                     PB.compile(option_rep_descriptor(),
                       projections: [{:"option_rep.Msg", adapter: @adapter}]
                     )
                   end
    end
  end

  describe "equality tolerance" do
    test "matching representation in :projections and proto-source merges without conflict" do
      schema =
        PB.compile(option_rep_descriptor(),
          projections: [
            {:"option_rep.Msg", struct: EventA}
          ]
        )

      assert schema.messages[:"option_rep.Msg"].projection.struct_mod == EventA
    end

    test "matching oneof representation in :projections and proto-source merges without conflict" do
      schema =
        PB.compile(option_rep_oneof_descriptor(),
          projections: [
            {:"option_rep_oneof.A", struct: EventA},
            {:"option_rep_oneof.B", struct: EventB},
            {:"option_rep_oneof.Outer", oneofs: [data: [representation: :identity]]}
          ]
        )

      assert schema.messages[:"option_rep_oneof.Outer"].projection.oneofs == %{data: :identity}
    end
  end

  describe "target validation" do
    test "unknown message target raises" do
      assert_raise ArgumentError, ~r/unknown PB projection target/, fn ->
        PB.compile(single_message_descriptor(),
          projections: [{:"proj.Missing", struct: EventA}]
        )
      end
    end

    test "unknown oneof target raises" do
      assert_raise ArgumentError, ~r/unknown PB projection target/, fn ->
        PB.compile(oneof_event_descriptor(),
          projections: [
            {:"proj.A", struct: EventA},
            {:"proj.B", struct: EventB},
            {:"proj.Event", oneofs: [missing: [representation: :identity]]}
          ]
        )
      end
    end

    test "map-entry message target raises" do
      assert_raise ArgumentError, ~r/cannot project map-entry message/, fn ->
        PB.compile(map_field_descriptor(),
          projections: [{:"proj_map.Bag.ItemsEntry", struct: EventA}]
        )
      end
    end
  end

  describe "standalone oneofs" do
    test "an entry with only :oneofs leaves the parent message unprojected" do
      schema =
        PB.compile(oneof_event_descriptor(),
          projections: [
            {:"proj.A", struct: EventA},
            {:"proj.B", struct: EventB},
            {:"proj.Event", oneofs: [data: [representation: :identity]]}
          ]
        )

      projection = schema.messages[:"proj.Event"].projection
      assert projection.adapter == nil
      assert projection.struct_mod == nil
      assert projection.unwrap_field == nil
      assert projection.oneofs == %{data: :identity}
    end
  end

  describe "Transform.projections re-application" do
    test "re-applying a projection that clashes with an existing one raises" do
      schema =
        PB.compile(single_message_descriptor(),
          projections: [{@message, struct: EventA}]
        )

      assert_raise ArgumentError,
                   ~r/conflicting PB projection for :"proj.Msg":.*existing schema.*compile-time :projections/s,
                   fn ->
                     PB.Schema.Transform.projections(
                       schema,
                       [{@message, struct: EventB}]
                     )
                   end
    end

    test "re-applying any adapter when one is already attached raises duplicate" do
      schema =
        PB.compile(single_message_descriptor(),
          projections: [{@message, adapter: @adapter}]
        )

      for adapter <- [@adapter, @other_adapter] do
        assert_raise ArgumentError, ~r/duplicate PB projection for :"proj.Msg"/, fn ->
          PB.Schema.Transform.projections(schema, [{@message, adapter: adapter}])
        end
      end
    end

    test "re-applying a representation when an adapter exists raises conflict" do
      schema =
        PB.compile(single_message_descriptor(),
          projections: [{@message, adapter: @adapter}]
        )

      assert_raise ArgumentError,
                   ~r/conflicting PB projection for :"proj.Msg":.*existing schema.*compile-time :projections/s,
                   fn ->
                     PB.Schema.Transform.projections(
                       schema,
                       [{@message, struct: EventA}]
                     )
                   end
    end
  end

  defp single_message_descriptor do
    %{
      file: [
        %{
          name: "proj.proto",
          package: "proj",
          syntax: "proto3",
          message_type: [
            %{name: "Msg", field: [%{name: "value", number: 1, type: :TYPE_STRING}]}
          ]
        }
      ]
    }
  end

  defp oneof_event_descriptor do
    %{
      file: [
        %{
          name: "proj_oneof.proto",
          package: "proj",
          syntax: "proto3",
          message_type: [
            %{name: "A", field: [%{name: "value", number: 1, type: :TYPE_STRING}]},
            %{name: "B", field: [%{name: "value", number: 1, type: :TYPE_STRING}]},
            %{
              name: "Event",
              oneof_decl: [%{name: "data"}],
              field: [
                %{
                  name: "a",
                  number: 1,
                  type: :TYPE_MESSAGE,
                  type_name: ".proj.A",
                  label: :LABEL_OPTIONAL,
                  oneof_index: 0
                },
                %{
                  name: "b",
                  number: 2,
                  type: :TYPE_MESSAGE,
                  type_name: ".proj.B",
                  label: :LABEL_OPTIONAL,
                  oneof_index: 0
                }
              ]
            }
          ]
        }
      ]
    }
  end

  defp map_field_descriptor do
    %{
      file: [
        %{
          name: "proj_map.proto",
          package: "proj_map",
          syntax: "proto3",
          message_type: [
            %{
              name: "Bag",
              field: [
                %{
                  name: "items",
                  number: 1,
                  type: :TYPE_MESSAGE,
                  type_name: ".proj_map.Bag.ItemsEntry",
                  label: :LABEL_REPEATED
                }
              ],
              nested_type: [
                %{
                  name: "ItemsEntry",
                  options: %{map_entry: true},
                  field: [
                    %{name: "key", number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                    %{name: "value", number: 2, type: :TYPE_INT32, label: :LABEL_OPTIONAL}
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
  end

  defp option_rep_descriptor do
    extensions = :__extensions__

    %{
      file: [
        %{
          name: "option_rep_proj.proto",
          package: "option_rep",
          syntax: "proto3",
          message_type: [
            %{
              name: "Msg",
              options: %{
                extensions => %{
                  :"elixir.pb.v1.message" => %{
                    struct: "PB.ProjectionsTest.EventA"
                  }
                }
              },
              field: [%{name: "value", number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}]
            }
          ]
        }
      ]
    }
  end

  defp option_rep_oneof_descriptor do
    extensions = :__extensions__

    %{
      file: [
        %{
          name: "option_rep_oneof_proj.proto",
          package: "option_rep_oneof",
          syntax: "proto3",
          message_type: [
            %{name: "A", field: [%{name: "value", number: 1, type: :TYPE_STRING}]},
            %{name: "B", field: [%{name: "value", number: 1, type: :TYPE_STRING}]},
            %{
              name: "Outer",
              oneof_decl: [
                %{
                  name: "data",
                  options: %{
                    extensions => %{
                      :"elixir.pb.v1.oneof" => %{representation: :IDENTITY}
                    }
                  }
                }
              ],
              field: [
                %{
                  name: "a",
                  number: 1,
                  type: :TYPE_MESSAGE,
                  type_name: ".option_rep_oneof.A",
                  label: :LABEL_OPTIONAL,
                  oneof_index: 0
                },
                %{
                  name: "b",
                  number: 2,
                  type: :TYPE_MESSAGE,
                  type_name: ".option_rep_oneof.B",
                  label: :LABEL_OPTIONAL,
                  oneof_index: 0
                }
              ]
            }
          ]
        }
      ]
    }
  end
end

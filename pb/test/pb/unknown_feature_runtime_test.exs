defmodule PB.UnknownFeatureRuntimeTest do
  use ExUnit.Case

  import PB.TestSupport.Assertions
  import PB.TestSupport.CodegenConsistency

  # ── Bootstrap / load ───────────────────────────────────────────────

  # ── T2 - Unknown field skipping ─────────────────────────────────────

  describe "T2 - unknown field skipping" do
    @full_desc %{
      file: [
        %{
          name: "skip.proto",
          package: :skip,
          syntax: :proto3,
          message_type: [
            %{
              name: :Msg,
              field: [
                %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                %{name: :id, number: 2, type: :TYPE_INT32, label: :LABEL_OPTIONAL},
                %{name: :score, number: 3, type: :TYPE_DOUBLE, label: :LABEL_OPTIONAL},
                %{name: :tag, number: 4, type: :TYPE_FIXED32, label: :LABEL_OPTIONAL},
                %{name: :data, number: 5, type: :TYPE_BYTES, label: :LABEL_OPTIONAL}
              ]
            }
          ],
          enum_type: []
        }
      ]
    }

    @partial_desc %{
      file: [
        %{
          name: "skip.proto",
          package: :skip,
          syntax: :proto3,
          message_type: [
            %{
              name: :Msg,
              field: [
                %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
              ]
            }
          ],
          enum_type: []
        }
      ]
    }

    setup do
      %{full: PB.compile(@full_desc), partial: PB.compile(@partial_desc)}
    end

    test "preserves unknown varint field (wire type 0)", %{full: full, partial: partial} do
      {:ok, bin} = PB.encode(%{name: "test", id: 42}, full, :"skip.Msg")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), partial, :"skip.Msg")

      assert decoded == %{
               :__unknown_fields__ => [
                 %PB.UnknownField{number: 2, wire_type: 0, raw: <<16, 42>>}
               ],
               name: "test"
             }
    end

    test "preserves unknown 64-bit field (wire type 1)", %{full: full, partial: partial} do
      {:ok, bin} = PB.encode(%{name: "test", score: 3.14}, full, :"skip.Msg")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), partial, :"skip.Msg")

      assert decoded == %{
               :__unknown_fields__ => [
                 %PB.UnknownField{
                   number: 3,
                   wire_type: 1,
                   raw: <<25, 31, 133, 235, 81, 184, 30, 9, 64>>
                 }
               ],
               name: "test"
             }
    end

    test "preserves unknown 32-bit field (wire type 5)", %{full: full, partial: partial} do
      {:ok, bin} = PB.encode(%{name: "test", tag: 99}, full, :"skip.Msg")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), partial, :"skip.Msg")

      assert decoded == %{
               :__unknown_fields__ => [
                 %PB.UnknownField{number: 4, wire_type: 5, raw: <<37, 99, 0, 0, 0>>}
               ],
               name: "test"
             }
    end

    test "preserves unknown length-delimited field (wire type 2)", %{full: full, partial: partial} do
      {:ok, bin} = PB.encode(%{name: "test", data: <<1, 2, 3>>}, full, :"skip.Msg")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), partial, :"skip.Msg")

      assert decoded == %{
               :__unknown_fields__ => [
                 %PB.UnknownField{number: 5, wire_type: 2, raw: <<42, 3, 1, 2, 3>>}
               ],
               name: "test"
             }
    end

    test "preserves unknown group field (wire types 3/4)", %{partial: partial} do
      group = <<0x33, 0x3B, 0x08, 0x2A, 0x3C, 0x34>>
      bin = IO.iodata_to_binary([<<0x0A, 0x04, "test">>, group])

      {:ok, decoded} = PB.decode(bin, partial, :"skip.Msg")

      assert decoded == %{
               :__unknown_fields__ => [
                 %PB.UnknownField{number: 6, wire_type: 3, raw: group}
               ],
               name: "test"
             }

      assert_decode_consistent(partial, :"skip.Msg", bin)

      {:ok, encoded} = PB.encode(decoded, partial, :"skip.Msg")
      assert IO.iodata_to_binary(encoded) == bin
    end

    test "preserves all unknown wire types at once", %{full: full, partial: partial} do
      {:ok, bin} =
        PB.encode(
          %{
            name: "test",
            id: 42,
            score: 3.14,
            tag: 99,
            data: <<1, 2, 3>>
          },
          full,
          :"skip.Msg"
        )

      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), partial, :"skip.Msg")

      assert decoded == %{
               :__unknown_fields__ => [
                 %PB.UnknownField{number: 2, wire_type: 0, raw: <<16, 42>>},
                 %PB.UnknownField{
                   number: 3,
                   wire_type: 1,
                   raw: <<25, 31, 133, 235, 81, 184, 30, 9, 64>>
                 },
                 %PB.UnknownField{number: 4, wire_type: 5, raw: <<37, 99, 0, 0, 0>>},
                 %PB.UnknownField{number: 5, wire_type: 2, raw: <<42, 3, 1, 2, 3>>}
               ],
               name: "test"
             }

      {:ok, encoded} = PB.encode(decoded, partial, :"skip.Msg")
      assert IO.iodata_to_binary(encoded) == IO.iodata_to_binary(bin)
    end
  end

  describe "T2b - feature settings" do
    test "edition defaults are compiled into effective field features" do
      schema =
        PB.compile(%{
          file: [
            %{
              name: "edition.proto",
              package: :feat,
              edition: :EDITION_2024,
              message_type: [
                %{
                  name: :Msg,
                  field: [
                    %{name: :count, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL}
                  ]
                }
              ],
              enum_type: []
            }
          ]
        })

      field = schema.messages[:"feat.Msg"].fields_by_name[:count]
      assert field.features.field_presence == :EXPLICIT

      assert {:ok, iodata} = PB.encode(%{count: 0}, schema, :"feat.Msg")
      assert IO.iodata_to_binary(iodata) == <<0x08, 0x00>>

      assert {:ok, %{"count" => 0}} = PB.JSON.to_term(%{count: 0}, schema, :"feat.Msg")
    end

    test "field feature overrides repeated encoding" do
      schema =
        PB.compile(%{
          file: [
            %{
              name: "encoding.proto",
              package: :feat,
              syntax: :proto3,
              message_type: [
                %{
                  name: :Msg,
                  field: [
                    %{
                      name: :nums,
                      number: 1,
                      type: :TYPE_INT32,
                      label: :LABEL_REPEATED,
                      options: %{features: %{repeated_field_encoding: :EXPANDED}}
                    }
                  ]
                }
              ],
              enum_type: []
            }
          ]
        })

      field = schema.messages[:"feat.Msg"].fields_by_name[:nums]
      assert field.features.repeated_field_encoding == :EXPANDED
      assert field.cardinality == :repeated
      assert field.encoding == :expanded

      assert {:ok, iodata} = PB.encode(%{nums: [1, 2]}, schema, :"feat.Msg")
      assert IO.iodata_to_binary(iodata) == <<0x08, 0x01, 0x08, 0x02>>
    end

    test "legacy required fields are enforced on encode and decode" do
      schema =
        PB.compile(%{
          file: [
            %{
              name: "required.proto",
              package: :feat,
              syntax: :proto2,
              message_type: [
                %{
                  name: :Msg,
                  field: [
                    %{name: :id, number: 1, type: :TYPE_INT32, label: :LABEL_REQUIRED}
                  ]
                }
              ],
              enum_type: []
            }
          ]
        })

      assert schema.messages[:"feat.Msg"].fields_by_name[:id].features.field_presence ==
               :LEGACY_REQUIRED

      assert schema.messages[:"feat.Msg"].fields_by_name[:id].presence == :required

      assert_error(PB.encode(%{}, schema, :"feat.Msg"),
        kind: :missing_required,
        path: [:id]
      )

      assert_error(PB.decode(<<>>, schema, :"feat.Msg"),
        kind: :missing_required,
        path: [:id]
      )

      assert {:ok, iodata} = PB.encode(%{id: 0}, schema, :"feat.Msg")
      assert IO.iodata_to_binary(iodata) == <<0x08, 0x00>>
      assert {:ok, %{id: 0}} = PB.decode(<<0x08, 0x00>>, schema, :"feat.Msg")
    end

    test "TYPE_GROUP compiles as a delimited message field" do
      schema =
        PB.compile(%{
          file: [
            %{
              name: "group.proto",
              package: :grp,
              syntax: :proto2,
              message_type: [
                %{
                  name: :Msg,
                  field: [
                    %{
                      name: :legacy,
                      number: 1,
                      type: :TYPE_GROUP,
                      label: :LABEL_OPTIONAL,
                      type_name: :"grp.Msg.Legacy"
                    }
                  ],
                  nested_type: [
                    %{
                      name: :Legacy,
                      field: [
                        %{name: :id, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL}
                      ]
                    }
                  ]
                }
              ],
              enum_type: []
            }
          ]
        })

      field = schema.messages[:"grp.Msg"].fields_by_name[:legacy]
      assert field.type == :TYPE_MESSAGE
      assert field.source.type == :TYPE_GROUP
      assert field.features.message_encoding == :DELIMITED
      assert field.wire_type == 3
      assert field.encoding == :delimited
      assert field.presence == :explicit

      value = %{legacy: %{id: 7}}
      assert {:ok, iodata} = PB.encode(value, schema, :"grp.Msg")
      assert IO.iodata_to_binary(iodata) == <<0x0B, 0x08, 0x07, 0x0C>>
      assert {:ok, ^value} = PB.decode(<<0x0B, 0x08, 0x07, 0x0C>>, schema, :"grp.Msg")
      assert_codec_roundtrip_consistent(prepare_codec(schema, :"grp.Msg"), value)
    end

    test "message_encoding DELIMITED uses group wire framing" do
      schema =
        PB.compile(%{
          file: [
            %{
              name: "delimited.proto",
              package: :grp,
              edition: :EDITION_2024,
              message_type: [
                %{
                  name: :Msg,
                  field: [
                    %{
                      name: :child,
                      number: 1,
                      type: :TYPE_MESSAGE,
                      label: :LABEL_OPTIONAL,
                      type_name: :"grp.Child",
                      options: %{features: %{message_encoding: :DELIMITED}}
                    }
                  ]
                },
                %{
                  name: :Child,
                  field: [
                    %{name: :id, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL}
                  ]
                }
              ],
              enum_type: []
            }
          ]
        })

      field = schema.messages[:"grp.Msg"].fields_by_name[:child]
      assert field.type == :TYPE_MESSAGE
      assert field.source.type == :TYPE_MESSAGE
      assert field.features.message_encoding == :DELIMITED
      assert field.wire_type == 3
      assert field.encoding == :delimited

      value = %{child: %{id: 9}}
      assert {:ok, iodata} = PB.encode(value, schema, :"grp.Msg")
      assert IO.iodata_to_binary(iodata) == <<0x0B, 0x08, 0x09, 0x0C>>
      assert {:ok, ^value} = PB.decode(<<0x0B, 0x08, 0x09, 0x0C>>, schema, :"grp.Msg")
      assert {:ok, %{"child" => %{"id" => 9}}} = PB.JSON.to_term(value, schema, :"grp.Msg")
      assert_codec_roundtrip_consistent(prepare_codec(schema, :"grp.Msg"), value)
    end
  end
end

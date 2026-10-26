defmodule PB.RepeatedEncodingTest do
  use ExUnit.Case

  import PB.TestSupport.Assertions
  import PB.TestSupport.CodegenConsistency, only: [assert_decode_consistent: 3]

  # ── T3 - Proto2 syntax ──────────────────────────────────────────────

  describe "T3 - proto2 packed defaults" do
    test "proto2 repeated scalar defaults to unpacked" do
      desc = %{
        file: [
          %{
            name: "p2.proto",
            package: :p2,
            syntax: :proto2,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{name: :vals, number: 1, type: :TYPE_INT32, label: :LABEL_REPEATED}
                ]
              }
            ],
            enum_type: []
          }
        ]
      }

      schema = PB.compile(desc)
      assert schema.messages[:"p2.Msg"].fields_by_name[:vals].encoding == :expanded
    end

    test "proto2 explicit packed=true" do
      desc = %{
        file: [
          %{
            name: "p2.proto",
            package: :p2,
            syntax: :proto2,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{
                    name: :vals,
                    number: 1,
                    type: :TYPE_INT32,
                    label: :LABEL_REPEATED,
                    options: %{packed: true}
                  }
                ]
              }
            ],
            enum_type: []
          }
        ]
      }

      schema = PB.compile(desc)
      assert schema.messages[:"p2.Msg"].fields_by_name[:vals].encoding == :packed
    end

    test "proto3 explicit packed=false" do
      desc = %{
        file: [
          %{
            name: "p3.proto",
            package: :p3,
            syntax: :proto3,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{
                    name: :vals,
                    number: 1,
                    type: :TYPE_INT32,
                    label: :LABEL_REPEATED,
                    options: %{packed: false}
                  }
                ]
              }
            ],
            enum_type: []
          }
        ]
      }

      schema = PB.compile(desc)
      assert schema.messages[:"p3.Msg"].fields_by_name[:vals].encoding == :expanded
    end

    test "proto2 unpacked repeated int32 round-trip" do
      desc = %{
        file: [
          %{
            name: "p2.proto",
            package: :p2,
            syntax: :proto2,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{name: :vals, number: 1, type: :TYPE_INT32, label: :LABEL_REPEATED}
                ]
              }
            ],
            enum_type: []
          }
        ]
      }

      schema = PB.compile(desc)
      {:ok, bin} = PB.encode(%{vals: [10, 20, 30]}, schema, :"p2.Msg")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), schema, :"p2.Msg")
      assert decoded.vals == [10, 20, 30]
    end

    test "proto2 explicit packed=true round-trip" do
      desc = %{
        file: [
          %{
            name: "p2.proto",
            package: :p2,
            syntax: :proto2,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{
                    name: :vals,
                    number: 1,
                    type: :TYPE_INT32,
                    label: :LABEL_REPEATED,
                    options: %{packed: true}
                  }
                ]
              }
            ],
            enum_type: []
          }
        ]
      }

      schema = PB.compile(desc)
      {:ok, bin} = PB.encode(%{vals: [10, 20, 30]}, schema, :"p2.Msg")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), schema, :"p2.Msg")
      assert decoded.vals == [10, 20, 30]
    end
  end

  # ── T4 - Proto3 optional (synthetic oneofs) ─────────────────────────

  describe "T4 - proto3 optional synthetic oneofs" do
    @opt_desc %{
      file: [
        %{
          name: "opt.proto",
          package: :opt,
          syntax: :proto3,
          message_type: [
            %{
              name: :Msg,
              field: [
                %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                %{
                  name: :nickname,
                  number: 2,
                  type: :TYPE_STRING,
                  label: :LABEL_OPTIONAL,
                  oneof_index: 0,
                  proto3_optional: true
                },
                %{
                  name: :a,
                  number: 3,
                  type: :TYPE_STRING,
                  label: :LABEL_OPTIONAL,
                  oneof_index: 1
                },
                %{
                  name: :b,
                  number: 4,
                  type: :TYPE_STRING,
                  label: :LABEL_OPTIONAL,
                  oneof_index: 1
                }
              ],
              oneof_decl: [%{name: :_nickname}, %{name: :choice}]
            }
          ],
          enum_type: []
        }
      ]
    }

    setup do
      %{os: PB.compile(@opt_desc)}
    end

    test "synthetic oneof is excluded from compiled oneofs", %{os: os} do
      msg = os.messages[:"opt.Msg"]
      assert map_size(msg.oneofs) == 1
      assert msg.oneofs[1].name == :choice
      assert msg.oneofs[1].fields == [:a, :b]

      nickname = msg.fields_by_name[:nickname]
      assert nickname.presence == :explicit
      refute Map.has_key?(nickname, :oneof_index)
      refute Map.has_key?(nickname, :proto3_optional)
      assert nickname.source.proto3_optional == true
      assert nickname.source.oneof_index == 0

      assert msg.fields_by_name[:a].presence == :oneof
      assert msg.fields_by_name[:a].oneof_index == 1
    end

    test "proto3_optional field encodes/decodes as plain field", %{os: os} do
      {:ok, bin} = PB.encode(%{nickname: "Nick"}, os, :"opt.Msg")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), os, :"opt.Msg")
      assert decoded.nickname == "Nick"
      refute Map.has_key?(decoded, :_nickname)
    end

    test "real oneof still works alongside proto3_optional", %{os: os} do
      {:ok, bin} =
        PB.encode(%{nickname: "Nick", choice: {:a, "hello"}}, os, :"opt.Msg")

      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), os, :"opt.Msg")
      assert decoded.nickname == "Nick"
      assert decoded.choice == {:a, "hello"}
    end
  end

  # ── T5 - Packed repeated for all packable types ─────────────────────

  describe "T5 - packed repeated for all packable types" do
    @packed_desc %{
      file: [
        %{
          name: "packed.proto",
          package: :pk,
          syntax: :proto3,
          message_type: [
            %{
              name: :Msg,
              field: [
                %{name: :doubles, number: 1, type: :TYPE_DOUBLE, label: :LABEL_REPEATED},
                %{name: :floats, number: 2, type: :TYPE_FLOAT, label: :LABEL_REPEATED},
                %{name: :int64s, number: 3, type: :TYPE_INT64, label: :LABEL_REPEATED},
                %{name: :uint64s, number: 4, type: :TYPE_UINT64, label: :LABEL_REPEATED},
                %{name: :int32s, number: 5, type: :TYPE_INT32, label: :LABEL_REPEATED},
                %{name: :fixed64s, number: 6, type: :TYPE_FIXED64, label: :LABEL_REPEATED},
                %{name: :fixed32s, number: 7, type: :TYPE_FIXED32, label: :LABEL_REPEATED},
                %{name: :bools, number: 8, type: :TYPE_BOOL, label: :LABEL_REPEATED},
                %{name: :uint32s, number: 9, type: :TYPE_UINT32, label: :LABEL_REPEATED},
                %{name: :sfixed32s, number: 10, type: :TYPE_SFIXED32, label: :LABEL_REPEATED},
                %{name: :sfixed64s, number: 11, type: :TYPE_SFIXED64, label: :LABEL_REPEATED},
                %{name: :sint32s, number: 12, type: :TYPE_SINT32, label: :LABEL_REPEATED},
                %{name: :sint64s, number: 13, type: :TYPE_SINT64, label: :LABEL_REPEATED},
                %{
                  name: :roles,
                  number: 14,
                  type: :TYPE_ENUM,
                  label: :LABEL_REPEATED,
                  type_name: :"pk.Role"
                }
              ]
            }
          ],
          enum_type: [
            %{
              name: :Role,
              value: [
                %{name: :NONE, number: 0},
                %{name: :ADMIN, number: 1},
                %{name: :USER, number: 2}
              ]
            }
          ]
        }
      ]
    }

    setup do
      %{ps: PB.compile(@packed_desc)}
    end

    test "packed doubles", %{ps: ps} do
      assert_packed_rt(ps, %{doubles: [1.1, 2.2, 3.3]})
    end

    test "packed floats", %{ps: ps} do
      {:ok, bin} = PB.encode(%{floats: [1.5, 2.5]}, ps, :"pk.Msg")
      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), ps, :"pk.Msg")
      assert length(d.floats) == 2
      assert_in_delta hd(d.floats), 1.5, 0.001
      assert_in_delta Enum.at(d.floats, 1), 2.5, 0.001
    end

    test "packed int64s", %{ps: ps} do
      assert_packed_rt(ps, %{int64s: [1_000_000_000_000, -1_000_000_000_000]})
    end

    test "packed uint64s", %{ps: ps} do
      assert_packed_rt(ps, %{uint64s: [0, 18_446_744_073_709_551_615]})
    end

    test "packed int32s", %{ps: ps} do
      assert_packed_rt(ps, %{int32s: [1, -1, 2_147_483_647, -2_147_483_648]})
    end

    test "packed fixed64s", %{ps: ps} do
      assert_packed_rt(ps, %{fixed64s: [0, 123_456_789, 18_446_744_073_709_551_615]})
    end

    test "packed fixed32s", %{ps: ps} do
      assert_packed_rt(ps, %{fixed32s: [0, 42, 4_294_967_295]})
    end

    test "packed bools", %{ps: ps} do
      assert_packed_rt(ps, %{bools: [true, false, true]})
    end

    test "packed uint32s", %{ps: ps} do
      assert_packed_rt(ps, %{uint32s: [0, 100, 4_294_967_295]})
    end

    test "packed sfixed32s", %{ps: ps} do
      assert_packed_rt(ps, %{sfixed32s: [-42, 0, 42]})
    end

    test "packed sfixed64s", %{ps: ps} do
      assert_packed_rt(ps, %{sfixed64s: [-999_999, 0, 999_999]})
    end

    test "packed sint32s", %{ps: ps} do
      assert_packed_rt(ps, %{sint32s: [-100, 0, 100]})
    end

    test "packed sint64s", %{ps: ps} do
      assert_packed_rt(ps, %{sint64s: [-100_000_000_000, 0, 100_000_000_000]})
    end

    test "packed enums", %{ps: ps} do
      assert_packed_rt(ps, %{roles: [:NONE, :ADMIN, :USER]})
    end

    defp assert_packed_rt(schema, data) do
      {:ok, bin} = PB.encode(data, schema, :"pk.Msg")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), schema, :"pk.Msg")
      assert decoded == data
    end
  end

  # ── T6 - Unpacked repeated scalars ──────────────────────────────────

  describe "T6 - unpacked repeated scalars" do
    test "proto2 decoder accepts packed encoding for unpacked field" do
      # Proto2 schema (field defaults to unpacked)
      desc_p2 = %{
        file: [
          %{
            name: "compat.proto",
            package: :compat,
            syntax: :proto2,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{name: :vals, number: 1, type: :TYPE_INT32, label: :LABEL_REPEATED}
                ]
              }
            ],
            enum_type: []
          }
        ]
      }

      # Proto3 schema (same structure, packed by default)
      desc_p3 = %{
        file: [
          %{
            name: "compat.proto",
            package: :compat,
            syntax: :proto3,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{name: :vals, number: 1, type: :TYPE_INT32, label: :LABEL_REPEATED}
                ]
              }
            ],
            enum_type: []
          }
        ]
      }

      s_p3 = PB.compile(desc_p3)
      s_p2 = PB.compile(desc_p2)

      # Encode with proto3 (packed)
      {:ok, packed_bin} = PB.encode(%{vals: [10, 20, 30]}, s_p3, :"compat.Msg")
      bin = IO.iodata_to_binary(packed_bin)

      # Decode with proto2 schema (unpacked field) — should still work
      {:ok, decoded} = PB.decode(bin, s_p2, :"compat.Msg")
      assert decoded.vals == [10, 20, 30]
    end

    test "unpacked repeated with multiple types" do
      desc = %{
        file: [
          %{
            name: "unp.proto",
            package: :unp,
            syntax: :proto2,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{name: :ints, number: 1, type: :TYPE_INT32, label: :LABEL_REPEATED},
                  %{name: :flags, number: 2, type: :TYPE_BOOL, label: :LABEL_REPEATED},
                  %{name: :big, number: 3, type: :TYPE_FIXED64, label: :LABEL_REPEATED}
                ]
              }
            ],
            enum_type: []
          }
        ]
      }

      schema = PB.compile(desc)

      data = %{ints: [1, 2, 3], flags: [true, false], big: [999, 0]}
      {:ok, bin} = PB.encode(data, schema, :"unp.Msg")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), schema, :"unp.Msg")
      assert decoded == data
    end
  end

  # ── T7 - Repeated enums ─────────────────────────────────────────────

  describe "T7 - repeated enums" do
    test "proto2 unpacked repeated enum round-trip" do
      desc = %{
        file: [
          %{
            name: "e.proto",
            package: :e,
            syntax: :proto2,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{
                    name: :roles,
                    number: 1,
                    type: :TYPE_ENUM,
                    label: :LABEL_REPEATED,
                    type_name: :"e.Role"
                  }
                ]
              }
            ],
            enum_type: [
              %{
                name: :Role,
                value: [%{name: :NONE, number: 0}, %{name: :ADMIN, number: 1}]
              }
            ]
          }
        ]
      }

      schema = PB.compile(desc)
      {:ok, bin} = PB.encode(%{roles: [:NONE, :ADMIN, :ADMIN]}, schema, :"e.Msg")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), schema, :"e.Msg")
      assert decoded.roles == [:NONE, :ADMIN, :ADMIN]
    end

    test "proto3 packed repeated enum round-trip" do
      desc = %{
        file: [
          %{
            name: "e3.proto",
            package: :e3,
            syntax: :proto3,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{
                    name: :roles,
                    number: 1,
                    type: :TYPE_ENUM,
                    label: :LABEL_REPEATED,
                    type_name: :"e3.Role"
                  }
                ]
              }
            ],
            enum_type: [
              %{
                name: :Role,
                value: [%{name: :NONE, number: 0}, %{name: :ADMIN, number: 1}]
              }
            ]
          }
        ]
      }

      schema = PB.compile(desc)
      {:ok, bin} = PB.encode(%{roles: [:NONE, :ADMIN, :ADMIN]}, schema, :"e3.Msg")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), schema, :"e3.Msg")
      assert decoded.roles == [:NONE, :ADMIN, :ADMIN]
    end

    test "closed enum unknown values are preserved as unknown fields" do
      desc = %{
        file: [
          %{
            name: "closed.proto",
            package: :closed,
            syntax: :proto2,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{
                    name: :role,
                    number: 1,
                    type: :TYPE_ENUM,
                    label: :LABEL_OPTIONAL,
                    type_name: :"closed.Role"
                  },
                  %{
                    name: :roles,
                    number: 2,
                    type: :TYPE_ENUM,
                    label: :LABEL_REPEATED,
                    type_name: :"closed.Role"
                  }
                ]
              }
            ],
            enum_type: [
              %{
                name: :Role,
                value: [%{name: :NONE, number: 0}, %{name: :ADMIN, number: 1}]
              }
            ]
          }
        ]
      }

      schema = PB.compile(desc)

      # role = 99, roles = [NONE, 99, ADMIN]
      bin = <<0x08, 99, 0x10, 0, 0x10, 99, 0x10, 1>>
      {:ok, decoded} = PB.decode(bin, schema, :"closed.Msg")

      assert decoded == %{
               :__unknown_fields__ => [
                 %PB.UnknownField{number: 1, wire_type: 0, raw: <<0x08, 99>>},
                 %PB.UnknownField{number: 2, wire_type: 0, raw: <<0x10, 99>>}
               ],
               roles: [:NONE, :ADMIN]
             }

      assert_error(PB.encode(%{role: 99}, schema, :"closed.Msg"),
        kind: :unknown_enum_value,
        path: [:role]
      )
    end

    test "packed closed enum unknown values are preserved as expanded unknown fields" do
      desc = %{
        file: [
          %{
            name: "closed_packed.proto",
            package: :closedp,
            syntax: :proto3,
            options: %{features: %{enum_type: :CLOSED}},
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{
                    name: :roles,
                    number: 1,
                    type: :TYPE_ENUM,
                    label: :LABEL_REPEATED,
                    type_name: :"closedp.Role"
                  }
                ]
              }
            ],
            enum_type: [
              %{
                name: :Role,
                value: [%{name: :NONE, number: 0}, %{name: :ADMIN, number: 1}]
              }
            ]
          }
        ]
      }

      schema = PB.compile(desc)

      # packed roles = [NONE, 99, ADMIN]
      {:ok, decoded} = PB.decode(<<0x0A, 3, 0, 99, 1>>, schema, :"closedp.Msg")

      assert decoded == %{
               :__unknown_fields__ => [
                 %PB.UnknownField{number: 1, wire_type: 0, raw: <<0x08, 99>>}
               ],
               roles: [:NONE, :ADMIN]
             }
    end

    test "only map entries with closed enum unknown values become unknown fields" do
      desc = %{
        file: [
          %{
            name: "closed_map.proto",
            package: :closedm,
            syntax: :proto2,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{
                    name: :roles,
                    number: 1,
                    type: :TYPE_MESSAGE,
                    label: :LABEL_REPEATED,
                    type_name: :"closedm.Msg.RolesEntry"
                  }
                ],
                nested_type: [
                  %{
                    name: :RolesEntry,
                    options: %{map_entry: true},
                    field: [
                      %{name: :key, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                      %{
                        name: :value,
                        number: 2,
                        type: :TYPE_ENUM,
                        label: :LABEL_OPTIONAL,
                        type_name: :"closedm.Role"
                      }
                    ]
                  }
                ]
              }
            ],
            enum_type: [
              %{
                name: :Role,
                value: [%{name: :NONE, number: 0}, %{name: :ADMIN, number: 1}]
              }
            ]
          }
        ]
      }

      schema = PB.compile(desc)

      # roles["a"] = 99. Closed enum map entries with unknown enum values become unknown.
      bin = <<0x0A, 5, 0x0A, 1, ?a, 0x10, 99>>
      {:ok, decoded} = PB.decode(bin, schema, :"closedm.Msg")

      assert decoded == %{
               :__unknown_fields__ => [
                 %PB.UnknownField{number: 1, wire_type: 2, raw: bin}
               ]
             }

      # Anything else inside an entry is skipped and the entry kept, as in C++
      # and Go: an unknown field 3, a value with the wrong wire type, a missing
      # key or value.
      for {bin, roles} <- [
            {<<0x0A, 7, 0x0A, 1, ?a, 0x10, 1, 0x18, 7>>, %{"a" => :ADMIN}},
            {<<0x0A, 6, 0x0A, 1, ?a, 0x12, 1, 1>>, %{"a" => :NONE}},
            {<<0x0A, 2, 0x10, 1>>, %{"" => :ADMIN}},
            {<<0x0A, 0>>, %{"" => :NONE}}
          ] do
        assert PB.decode(bin, schema, :"closedm.Msg") == {:ok, %{roles: roles}}
        assert_decode_consistent(schema, :"closedm.Msg", bin)
      end

      assert_decode_consistent(schema, :"closedm.Msg", <<0x0A, 5, 0x0A, 1, ?a, 0x10, 99>>)
    end

    test "a message value repeated inside one map entry merges" do
      schema = PB.TestSupport.TestSchema
      message = :"protobuf_test_messages.proto3.TestAllTypesProto3"
      field = schema.schema().messages[message].fields_by_name.map_string_nested_message

      entry =
        <<0x0A, 1, ?x>> <>
          <<0x12, 2, 0x08, 1>> <> <<0x12, 4, 0x12, 2, 0x08, 2>>

      bin = PB.Wire.encode_tag(field.number, 2) <> <<byte_size(entry)>> <> entry

      assert {:ok, %{map_string_nested_message: %{"x" => value}}} =
               PB.decode(bin, schema, message)

      assert value == %{a: 1, corecursive: %{optional_int32: 2}}
    end
  end
end

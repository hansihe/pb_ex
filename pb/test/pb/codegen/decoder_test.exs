defmodule PB.Codegen.DecoderTest do
  use ExUnit.Case

  import PB.TestSupport.CodegenConsistency

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
              %{name: :scores, number: 6, type: :TYPE_INT32, label: :LABEL_REPEATED},
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
            ]
          },
          %{
            name: :PhoneNumber,
            field: [
              %{name: :number, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
            ]
          },
          %{
            name: :Pet,
            field: [%{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}]
          },
          %{
            name: :Fish,
            field: [%{name: :species, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}]
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

  setup_all do
    %{person_decoder: prepare_decoder(@schema, :"test.Person")}
  end

  defp assert_error(result, attrs) do
    assert {:error, %{__exception__: true} = error} = result

    Enum.each(attrs, fn {key, value} ->
      assert Map.fetch!(error, key) == value
    end)

    error
  end

  defp person_defaults(attrs \\ %{}) do
    Map.merge(
      %{name: "", id: 0, phones: [], role: :UNKNOWN, scores: [], tags: %{}},
      attrs
    )
  end

  test "decodes a simple Person", %{person_decoder: decoder} do
    msg = %{name: "Alice", id: 42}

    assert {:ok, decoded} = assert_decode_roundtrip_consistent(decoder, msg)
    assert decoded == person_defaults(msg)
  end

  test "decodes nested messages", %{person_decoder: decoder} do
    msg = %{
      name: "Bob",
      id: 7,
      phones: [%{number: "555-1234"}, %{number: "555-5678"}]
    }

    assert {:ok, decoded} = assert_decode_roundtrip_consistent(decoder, msg)
    assert decoded == person_defaults(msg)
  end

  test "decodes enum field", %{person_decoder: decoder} do
    msg = %{name: "Carol", role: :ADMIN}

    assert {:ok, generated} = assert_decode_roundtrip_consistent(decoder, msg)
    assert generated.role == :ADMIN
  end

  test "decodes unknown enum value as integer", %{person_decoder: decoder} do
    # Build a binary manually with a value not in the enum.
    msg = %{name: "Dave", role: :UNKNOWN}
    {:ok, iodata} = PB.encode(msg, @schema, :"test.Person")
    # Swap role value (field 5) to 42. The wire format has tag byte (5<<3)|0 = 0x28.
    bin = IO.iodata_to_binary(iodata) <> <<0x28, 42>>

    assert {:ok, generated} = assert_decode_consistent(decoder, bin)
    assert generated.role == 42
  end

  test "decodes packed repeated scores", %{person_decoder: decoder} do
    msg = %{scores: [10, -20, 30, -40, 50]}

    assert {:ok, generated} = assert_decode_roundtrip_consistent(decoder, msg)
    assert generated.scores == [10, -20, 30, -40, 50]
  end

  test "decodes over-wide sint32 varints with 32-bit semantics" do
    schema =
      PB.compile(%{
        file: [
          %{
            name: "sint32.proto",
            package: :sint32,
            syntax: :proto3,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{name: :value, number: 1, type: :TYPE_SINT32, label: :LABEL_OPTIONAL},
                  %{name: :values, number: 2, type: :TYPE_SINT32, label: :LABEL_REPEATED}
                ]
              }
            ],
            enum_type: []
          }
        ]
      })

    decoder = prepare_decoder(schema, :"sint32.Msg")
    over_wide_one = <<0x82, 0x80, 0x80, 0x80, 0x10>>
    packed = <<0x12, byte_size(over_wide_one), over_wide_one::binary>>

    assert {:ok, %{value: 1, values: [1]}} =
             assert_decode_consistent(decoder, <<0x08, over_wide_one::binary, packed::binary>>)
  end

  test "rejects noncanonical tag varints but allows noncanonical scalar varints" do
    schema =
      PB.compile(%{
        file: [
          %{
            name: "varint.proto",
            package: :varint,
            syntax: :proto3,
            message_type: [
              %{
                name: :Msg,
                field: [%{name: :value, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL}]
              }
            ],
            enum_type: []
          }
        ]
      })

    decoder = prepare_decoder(schema, :"varint.Msg")

    assert {:ok, %{value: 1}} = assert_decode_consistent(decoder, <<0x08, 0x81, 0x00>>)

    error =
      assert_error(assert_decode_consistent(decoder, <<0x88, 0x00, 0x01>>),
        operation: :decode,
        message_name: :"varint.Msg",
        kind: :malformed,
        path: [],
        reason: :noncanonical_varint
      )

    assert error.details == %{}
  end

  test "enforces string UTF-8 according to schema features" do
    schema =
      PB.compile(%{
        file: [
          %{
            name: "utf8.proto",
            package: :utf8,
            syntax: :proto3,
            message_type: [
              %{
                name: :Proto3Msg,
                field: [%{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}]
              }
            ],
            enum_type: []
          },
          %{
            name: "utf8_proto2.proto",
            package: :utf8_proto2,
            syntax: :proto2,
            message_type: [
              %{
                name: :Msg,
                field: [%{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}]
              }
            ],
            enum_type: []
          }
        ]
      })

    invalid = <<0x0A, 0x01, 0xFF>>
    proto3_decoder = prepare_decoder(schema, :"utf8.Proto3Msg")
    proto2_decoder = prepare_decoder(schema, :"utf8_proto2.Msg")

    assert_error(assert_decode_consistent(proto3_decoder, invalid),
      operation: :decode,
      message_name: :"utf8.Proto3Msg",
      kind: :malformed,
      path: [:name],
      reason: :invalid_utf8
    )

    assert {:ok, %{name: <<0xFF>>}} = assert_decode_consistent(proto2_decoder, invalid)
  end

  test "generates linear postprocessing for many repeated fields" do
    fields =
      for n <- 1..32 do
        %{name: :"f#{n}", number: n, type: :TYPE_INT32, label: :LABEL_REPEATED}
      end

    schema =
      PB.compile(%{
        file: [
          %{
            name: "stress.proto",
            package: :stress,
            syntax: :proto3,
            message_type: [%{name: :Msg, field: fields}],
            enum_type: []
          }
        ]
      })

    decoder = prepare_decoder(schema, :"stress.Msg")
    msg = Map.new(1..32, fn n -> {:"f#{n}", [n, -n]} end)

    assert {:ok, ^msg} = assert_decode_roundtrip_consistent(decoder, msg)
  end

  test "decodes map field (tags)", %{person_decoder: decoder} do
    msg = %{tags: %{"a" => 1, "b" => 2, "c" => 3}}

    assert {:ok, generated} = assert_decode_roundtrip_consistent(decoder, msg)
    assert generated.tags == %{"a" => 1, "b" => 2, "c" => 3}
  end

  test "decodes oneof (pet)", %{person_decoder: decoder} do
    msg = %{companion: {:pet, %{name: "Rex"}}}

    assert {:ok, generated} = assert_decode_roundtrip_consistent(decoder, msg)
    assert generated.companion == {:pet, %{name: "Rex"}}
  end

  test "decodes oneof (fish) - last-wins when both on wire", %{person_decoder: decoder} do
    # Emit pet then fish; fish should win.
    pet_msg = %{companion: {:pet, %{name: "Rex"}}}
    fish_msg = %{companion: {:fish, %{species: "cod"}}}
    {:ok, pet_bin} = PB.encode(pet_msg, @schema, :"test.Person")
    {:ok, fish_bin} = PB.encode(fish_msg, @schema, :"test.Person")
    combined = IO.iodata_to_binary(pet_bin) <> IO.iodata_to_binary(fish_bin)

    assert {:ok, generated} = assert_decode_consistent(decoder, combined)
    assert generated.companion == {:fish, %{species: "cod"}}
  end

  test "decodes empty message", %{person_decoder: decoder} do
    assert {:ok, generated} = assert_decode_roundtrip_consistent(decoder, %{})
    assert generated == person_defaults()
  end

  test "defaults missing map-entry keys and values" do
    schema =
      PB.compile(%{
        file: [
          %{
            name: "map_defaults.proto",
            package: :mdef,
            syntax: :proto3,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{
                    name: :lookup,
                    number: 1,
                    type: :TYPE_MESSAGE,
                    label: :LABEL_REPEATED,
                    type_name: :"mdef.Msg.LookupEntry"
                  }
                ],
                nested_type: [
                  %{
                    name: :LookupEntry,
                    options: %{map_entry: true},
                    field: [
                      %{name: :key, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                      %{name: :value, number: 2, type: :TYPE_INT32, label: :LABEL_OPTIONAL}
                    ]
                  }
                ]
              }
            ],
            enum_type: []
          }
        ]
      })

    decoder = prepare_decoder(schema, :"mdef.Msg")

    only_key = <<0x0A, 0x03, 0x0A, 0x01, "a">>
    assert {:ok, %{lookup: %{"a" => 0}}} = assert_decode_consistent(decoder, only_key)

    only_value = <<0x0A, 0x02, 0x10, 42>>
    assert {:ok, %{lookup: %{"" => 42}}} = assert_decode_consistent(decoder, only_value)
  end

  test "leaves absent singular messages absent and defaults present empty messages" do
    schema =
      PB.compile(%{
        file: [
          %{
            name: "nested_defaults.proto",
            package: :ndef,
            syntax: :proto3,
            message_type: [
              %{
                name: :Outer,
                field: [
                  %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                  %{
                    name: :inner,
                    number: 2,
                    type: :TYPE_MESSAGE,
                    label: :LABEL_OPTIONAL,
                    type_name: :"ndef.Inner"
                  }
                ]
              },
              %{
                name: :Inner,
                field: [
                  %{name: :count, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL}
                ]
              }
            ],
            enum_type: []
          }
        ]
      })

    decoder = prepare_decoder(schema, :"ndef.Outer")

    assert {:ok, %{name: ""} = decoded} = assert_decode_consistent(decoder, <<>>)
    refute Map.has_key?(decoded, :inner)

    assert {:ok, %{name: "", inner: %{count: 0}}} =
             assert_decode_consistent(decoder, <<0x12, 0x00>>)
  end

  test "preserves explicit presence for proto3 optional and proto2 scalars" do
    schema =
      PB.compile(%{
        file: [
          %{
            name: "presence.proto",
            package: :presence,
            syntax: :proto3,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{name: :count, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL},
                  %{
                    name: :maybe,
                    number: 2,
                    type: :TYPE_INT32,
                    label: :LABEL_OPTIONAL,
                    oneof_index: 0,
                    proto3_optional: true
                  }
                ],
                oneof_decl: [%{name: :_maybe}]
              }
            ],
            enum_type: []
          },
          %{
            name: "presence_proto2.proto",
            package: :presence2,
            syntax: :proto2,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{name: :count, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL},
                  %{name: :items, number: 2, type: :TYPE_INT32, label: :LABEL_REPEATED}
                ]
              }
            ],
            enum_type: []
          }
        ]
      })

    optional_decoder = prepare_decoder(schema, :"presence.Msg")
    proto2_decoder = prepare_decoder(schema, :"presence2.Msg")

    assert apply(optional_decoder.module, optional_decoder.decode, [<<>>]) == {:ok, %{count: 0}}
    assert apply(proto2_decoder.module, proto2_decoder.decode, [<<>>]) == {:ok, %{items: []}}
  end

  test "preserves unknown fields", %{person_decoder: decoder} do
    # Encode a person, append a tag for a non-existent field 99 with a varint.
    {:ok, iodata} = PB.encode(%{name: "Eve"}, @schema, :"test.Person")
    # tag: (99 <<< 3) | 0 = 792 = encoded as varint
    unknown = <<0x98, 0x06, 0x2A>>
    bin = IO.iodata_to_binary(iodata) <> unknown

    assert {:ok, decoded} = assert_decode_consistent(decoder, bin)

    assert decoded ==
             person_defaults(%{
               :__unknown_fields__ => [
                 %PB.UnknownField{number: 99, wire_type: 0, raw: unknown}
               ],
               name: "Eve"
             })
  end

  test "enforces required fields consistently" do
    schema =
      PB.compile(%{
        file: [
          %{
            name: "required.proto",
            package: :req,
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

    decoder = prepare_decoder(schema, :"req.Msg")

    assert {:error, %PB.ValueError{kind: :missing_required, path: [:id]}} =
             assert_decode_consistent(decoder, <<>>)

    assert {:ok, %{id: 0}} = assert_decode_consistent(decoder, <<0x08, 0x00>>)
  end

  test "preserves closed enum unknown values consistently" do
    schema =
      PB.compile(%{
        file: [
          %{
            name: "closed.proto",
            package: :closedgen,
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
                    type_name: :"closedgen.Role"
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
      })

    decoder = prepare_decoder(schema, :"closedgen.Msg")

    assert {:ok, decoded} = assert_decode_consistent(decoder, <<0x0A, 3, 0, 99, 1>>)

    assert decoded == %{
             :__unknown_fields__ => [
               %PB.UnknownField{number: 1, wire_type: 0, raw: <<0x08, 99>>}
             ],
             roles: [:NONE, :ADMIN]
           }
  end

  test "bang decoder returns decoded value", %{person_decoder: decoder} do
    {:ok, iodata} = PB.encode(%{name: "Eve"}, @schema, :"test.Person")
    bin = IO.iodata_to_binary(iodata)

    assert apply(decoder.module, decoder.decode!, [bin]) == person_defaults(%{name: "Eve"})
  end

  test "returns structured error for non-binary input", %{person_decoder: decoder} do
    assert_error(assert_decode_consistent(decoder, :not_binary),
      operation: :decode,
      message_name: :"test.Person",
      kind: :invalid_value,
      path: []
    )
  end

  test "keeps fields with the wrong wire type as unknown fields", %{person_decoder: decoder} do
    # Field 1 (:name) is length-delimited. Encode the same field number with
    # varint wire type to exercise generated compatibility checks.
    assert {:ok, decoded} = assert_decode_consistent(decoder, <<0x08, 0x2A>>)
    assert decoded.__unknown_fields__ == [PB.UnknownField.from_raw(1, 0, <<0x2A>>)]
  end

  test "returns structured nested repeated field path for malformed input", %{
    person_decoder: decoder
  } do
    phone = <<0x0A, 0x05, "x">>
    bin = <<0x22, byte_size(phone)>> <> phone

    assert_error(assert_decode_consistent(decoder, bin),
      operation: :decode,
      message_name: :"test.Person",
      kind: :malformed,
      path: [:phones, {:index, 0}, :number],
      reason: :truncated_length_delimited
    )
  end

  test "bang decoder raises structured errors", %{person_decoder: decoder} do
    assert_raise PB.DecodeError, ~r/truncated_length_delimited/, fn ->
      apply(decoder.module, decoder.decode!, [<<0x0A, 0x05, "x">>])
    end
  end
end

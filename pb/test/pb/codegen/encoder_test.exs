defmodule PB.Codegen.EncoderTest do
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
    %{codec: prepare_codec(@schema, :"test.Person")}
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

  test "encodes a full message consistently", %{codec: codec} do
    msg = %{
      name: "Alice",
      id: 42,
      phones: [%{number: "555-1234"}, %{number: "555-5678"}],
      role: :ADMIN,
      scores: [10, -20, 30],
      companion: {:pet, %{name: "Rex"}},
      tags: %{"a" => 1, "b" => 2}
    }

    assert {:ok, decoded} = assert_codec_roundtrip_consistent(codec, msg)
    assert decoded == person_defaults(msg)
  end

  test "encodes nils and empty packed lists consistently", %{codec: codec} do
    msg = %{name: nil, id: 7, scores: []}

    assert {:ok, encoded} = assert_encode_consistent(codec, msg)
    assert IO.iodata_to_binary(encoded) == <<0x10, 0x07>>
  end

  test "root nil message is an absent encode result", %{codec: codec} do
    assert_error(PB.encode(nil, @schema, :"test.Person"),
      operation: :encode,
      kind: :absent,
      message_name: :"test.Person",
      path: []
    )

    assert_error(apply(codec.module, codec.encode, [nil]),
      operation: :encode,
      kind: :absent,
      message_name: :"test.Person",
      path: []
    )
  end

  test "elides implicit-presence scalar defaults", %{codec: codec} do
    assert {:ok, generated} = apply(codec.module, codec.encode, [person_defaults()])
    assert IO.iodata_to_binary(generated) == <<>>
  end

  test "rejects invalid UTF-8 strings for proto3", %{codec: codec} do
    msg = %{name: <<255>>}

    assert_error(assert_encode_consistent(codec, msg),
      operation: :encode,
      message_name: :"test.Person",
      kind: :invalid_value,
      path: [:name],
      expected: :utf8_string, got: :binary
    )
  end

  test "encodes all scalar types consistently" do
    schema =
      PB.compile(%{
        file: [
          %{
            name: "scalars.proto",
            package: :scalars,
            syntax: :proto3,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{name: :f_double, number: 1, type: :TYPE_DOUBLE, label: :LABEL_OPTIONAL},
                  %{name: :f_float, number: 2, type: :TYPE_FLOAT, label: :LABEL_OPTIONAL},
                  %{name: :f_int64, number: 3, type: :TYPE_INT64, label: :LABEL_OPTIONAL},
                  %{name: :f_uint64, number: 4, type: :TYPE_UINT64, label: :LABEL_OPTIONAL},
                  %{name: :f_int32, number: 5, type: :TYPE_INT32, label: :LABEL_OPTIONAL},
                  %{name: :f_fixed64, number: 6, type: :TYPE_FIXED64, label: :LABEL_OPTIONAL},
                  %{name: :f_fixed32, number: 7, type: :TYPE_FIXED32, label: :LABEL_OPTIONAL},
                  %{name: :f_bool, number: 8, type: :TYPE_BOOL, label: :LABEL_OPTIONAL},
                  %{name: :f_string, number: 9, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                  %{name: :f_bytes, number: 10, type: :TYPE_BYTES, label: :LABEL_OPTIONAL},
                  %{name: :f_uint32, number: 11, type: :TYPE_UINT32, label: :LABEL_OPTIONAL},
                  %{name: :f_sfixed32, number: 12, type: :TYPE_SFIXED32, label: :LABEL_OPTIONAL},
                  %{name: :f_sfixed64, number: 13, type: :TYPE_SFIXED64, label: :LABEL_OPTIONAL},
                  %{name: :f_sint32, number: 14, type: :TYPE_SINT32, label: :LABEL_OPTIONAL},
                  %{name: :f_sint64, number: 15, type: :TYPE_SINT64, label: :LABEL_OPTIONAL}
                ]
              }
            ]
          }
        ]
      })

    codec = prepare_codec(schema, :"scalars.Msg")

    msg = %{
      f_double: 3.14,
      f_float: 1.5,
      f_int64: -9_999_999_999,
      f_uint64: 18_446_744_073_709_551_615,
      f_int32: -42,
      f_fixed64: 123_456_789,
      f_fixed32: 42,
      f_bool: true,
      f_string: "text",
      f_bytes: <<0, 1, 2, 255>>,
      f_uint32: 4_294_967_295,
      f_sfixed32: -42,
      f_sfixed64: -999_999,
      f_sint32: -100,
      f_sint64: -100_000_000_000
    }

    assert {:ok, _decoded} = assert_codec_roundtrip_consistent(codec, msg)
  end

  test "encodes packed packable fields consistently" do
    schema =
      PB.compile(%{
        file: [
          %{
            name: "packed.proto",
            package: :packed,
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
                    type_name: :"packed.Role"
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
      })

    codec = prepare_codec(schema, :"packed.Msg")

    msg = %{
      doubles: [1.1, 2.2],
      floats: [1.5, 2.5],
      int64s: [1_000_000_000_000, -1_000_000_000_000],
      uint64s: [0, 18_446_744_073_709_551_615],
      int32s: [1, -1],
      fixed64s: [0, 123_456_789],
      fixed32s: [0, 42],
      bools: [true, false],
      uint32s: [0, 4_294_967_295],
      sfixed32s: [-42, 42],
      sfixed64s: [-999_999, 999_999],
      sint32s: [-100, 100],
      sint64s: [-100_000_000_000, 100_000_000_000],
      roles: [:NONE, :ADMIN, :USER]
    }

    assert {:ok, _decoded} = assert_codec_roundtrip_consistent(codec, msg)
  end

  test "supports unknown field ignore option", %{codec: codec} do
    msg = %{name: "Alice", bogus: "ignored"}

    assert {:ok, encoded} =
             assert_encode_consistent(codec, msg, encode_opts: [unknown_fields: :ignore])

    assert {:ok, %{name: "Alice"}} =
             PB.decode(IO.iodata_to_binary(encoded), codec.schema, codec.root)
  end

  test "returns structured unknown field errors by default", %{codec: codec} do
    assert_error(assert_encode_consistent(codec, %{name: "Alice", bogus: "ignored"}),
      operation: :encode,
      kind: :unknown_field,
      message_name: :"test.Person",
      path: [:bogus],
      protobuf_message: :"test.Person"
    )
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

    codec = prepare_codec(schema, :"req.Msg")

    assert_error(assert_encode_consistent(codec, %{}),
      operation: :encode,
      kind: :missing_required,
      message_name: :"req.Msg",
      path: [:id]
    )

    assert {:ok, iodata} = assert_encode_consistent(codec, %{id: 0})
    assert IO.iodata_to_binary(iodata) == <<0x08, 0x00>>
  end

  test "returns structured nested validation errors", %{codec: codec} do
    assert_error(assert_encode_consistent(codec, %{phones: [%{number: 123}]}),
      operation: :encode,
      kind: :invalid_value,
      message_name: :"test.Person",
      path: [:phones, {:index, 0}, :number],
      expected: :string, got: :integer
    )
  end

  test "returns structured oneof validation errors", %{codec: codec} do
    assert_error(assert_encode_consistent(codec, %{pet: %{name: "Rex"}}),
      operation: :encode,
      kind: :invalid_oneof,
      message_name: :"test.Person",
      path: [:pet],
      reason: :oneof_member_must_use_wrapper
    )
  end

  test "bang encoder raises structured errors", %{codec: codec} do
    assert_raise PB.ValueError, ~r/unknown field bogus/, fn ->
      apply(codec.module, codec.encode!, [%{bogus: true}])
    end
  end
end

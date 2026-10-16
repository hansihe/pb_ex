defmodule PB.CoreRuntimeTest do
  use ExUnit.Case

  import PB.TestSupport.Assertions
  import PB.TestSupport.CodegenConsistency

  alias PB.TestSupport.Fixtures

  setup_all do
    schema = PB.compile(Fixtures.person_descriptor_set())
    %{schema: schema, person_decoder: prepare_decoder(schema, :"test.Person")}
  end

  # ── Compiler ──────────────────────────────────────────────────────

  test "compile builds messages and enums", %{schema: schema} do
    assert Map.has_key?(schema.messages, :"test.Person")
    assert Map.has_key?(schema.messages, :"test.PhoneNumber")
    assert Map.has_key?(schema.messages, :"test.Person.TagsEntry")
    assert Map.has_key?(schema.enums, :"test.Role")

    person = schema.messages[:"test.Person"]
    assert person.fields_by_name[:name].wire_type == 2
    assert person.fields_by_name[:id].wire_type == 0
    assert person.fields_by_number[1].name == :name
    assert person.map_entry == false
    assert schema.messages[:"test.Person.TagsEntry"].map_entry == true
    assert person.fields_by_name[:name].cardinality == :singular
    assert person.fields_by_name[:name].presence == :implicit
    assert person.fields_by_name[:tags].cardinality == :map
    assert person.fields_by_name[:tags].presence == :none
    assert person.fields_by_name[:tags].map_entry.map_entry == true
  end

  test "compile resolves oneofs", %{schema: schema} do
    person = schema.messages[:"test.Person"]
    assert person.oneofs[0].name == :companion
    assert :pet in person.oneofs[0].fields
    assert :fish in person.oneofs[0].fields
  end

  test "compile sets packed for proto3 repeated scalars", %{schema: schema} do
    person = schema.messages[:"test.Person"]
    scores = person.fields_by_name[:scores]
    assert scores.cardinality == :repeated
    assert scores.presence == :none
    assert scores.encoding == :packed
  end

  # ── Schema slicing ────────────────────────────────────────────────

  describe "schema slicing" do
    setup do
      schema = PB.compile(Fixtures.binding_descriptor_set())
      %{schema: schema}
    end

    test "slice keeps roots, reachable messages, map entries, and enums", %{schema: schema} do
      sliced = PB.Schema.Transform.slice(schema, roots: [{:"bind.Event", as: :event}])

      assert sliced.roots == [:"bind.Event"]
      assert sliced.root_names == %{:"bind.Event" => :event}
      assert Map.has_key?(sliced.messages, :"bind.Event")
      assert Map.has_key?(sliced.messages, :"bind.Event.LabelsEntry")
      assert Map.has_key?(sliced.messages, :"bind.Note")
      refute Map.has_key?(sliced.messages, :"bind.Other")
      assert Map.has_key?(sliced.enums, :"bind.Role")

      data = %{note: %{text: "sliced"}, labels: %{"a" => %{text: "alpha"}}}
      {:ok, iodata} = PB.encode(data, sliced, :"bind.Event")

      assert {:ok, ^data} =
               PB.decode(IO.iodata_to_binary(iodata), sliced, :"bind.Event")
    end

    test "slice is a narrowing operation", %{schema: schema} do
      sliced = PB.Schema.Transform.slice(schema, roots: [:"bind.Event"])
      assert Map.has_key?(sliced.messages, :"bind.Note")

      narrowed = PB.Schema.Transform.slice(sliced, roots: [:"bind.Note"])
      assert narrowed.roots == [:"bind.Note"]
      assert Map.keys(narrowed.messages) == [:"bind.Note"]

      assert_raise ArgumentError, ~r/unknown PB slice root :"bind.Other"/, fn ->
        PB.Schema.Transform.slice(sliced, roots: [:"bind.Other"])
      end
    end
  end

  # ── Wire primitives (round-trip via encode/decode) ─────────────────

  describe "simple scalar encode/decode" do
    test "string field", %{person_decoder: decoder} do
      {:ok, decoded} = assert_decode_roundtrip_consistent(decoder, %{name: "Alice"})

      assert decoded.name == "Alice"
    end

    test "int32 field", %{person_decoder: decoder} do
      {:ok, decoded} = assert_decode_roundtrip_consistent(decoder, %{id: 42})
      assert decoded.id == 42
    end

    test "negative int32", %{person_decoder: decoder} do
      {:ok, decoded} = assert_decode_roundtrip_consistent(decoder, %{id: -1})
      assert decoded.id == -1
    end

    test "enum field as atom", %{person_decoder: decoder} do
      {:ok, decoded} = assert_decode_roundtrip_consistent(decoder, %{role: :ADMIN})
      assert decoded.role == :ADMIN
    end

    test "enum field as integer", %{person_decoder: decoder} do
      {:ok, decoded} = assert_decode_roundtrip_consistent(decoder, %{role: 2})
      assert decoded.role == :USER
    end
  end

  # ── Submessage ─────────────────────────────────────────────────────

  test "repeated submessage", %{person_decoder: decoder} do
    data = %{phones: [%{number: "+1234567890"}, %{number: "+0987654321"}]}
    {:ok, decoded} = assert_decode_roundtrip_consistent(decoder, data)
    assert length(decoded.phones) == 2
    assert Enum.at(decoded.phones, 0).number == "+1234567890"
    assert Enum.at(decoded.phones, 1).number == "+0987654321"
  end

  # ── Packed repeated ────────────────────────────────────────────────

  test "packed repeated int32", %{person_decoder: decoder} do
    data = %{scores: [100, 95, 88]}
    {:ok, decoded} = assert_decode_roundtrip_consistent(decoder, data)
    assert decoded.scores == [100, 95, 88]
  end

  # ── Oneof ──────────────────────────────────────────────────────────

  test "oneof pet", %{person_decoder: decoder} do
    data = %{companion: {:pet, %{name: "Rex"}}}
    {:ok, decoded} = assert_decode_roundtrip_consistent(decoder, data)
    assert decoded.companion == {:pet, %{name: "Rex"}}
  end

  test "oneof fish", %{person_decoder: decoder} do
    data = %{companion: {:fish, %{species: "Goldfish"}}}
    {:ok, decoded} = assert_decode_roundtrip_consistent(decoder, data)
    assert decoded.companion == {:fish, %{species: "Goldfish"}}
  end

  # ── Map fields ─────────────────────────────────────────────────────

  test "map<string, int32>", %{person_decoder: decoder} do
    data = %{tags: %{"team" => 1, "level" => 5}}
    {:ok, decoded} = assert_decode_roundtrip_consistent(decoder, data)
    assert decoded.tags == %{"team" => 1, "level" => 5}
  end

  describe "wire merge semantics" do
    setup do
      schema =
        PB.compile(%{
          file: [
            %{
              name: "merge.proto",
              package: :merge,
              syntax: :proto2,
              message_type: [
                %{
                  name: :Parent,
                  field: [
                    %{
                      name: :child,
                      number: 1,
                      type: :TYPE_MESSAGE,
                      label: :LABEL_OPTIONAL,
                      type_name: :"merge.Child"
                    },
                    %{
                      name: :children,
                      number: 2,
                      type: :TYPE_MESSAGE,
                      label: :LABEL_REPEATED,
                      type_name: :"merge.Child"
                    },
                    %{
                      name: :children_by_name,
                      number: 3,
                      type: :TYPE_MESSAGE,
                      label: :LABEL_REPEATED,
                      type_name: :"merge.Parent.ChildrenByNameEntry"
                    },
                    %{
                      name: :kid,
                      number: 4,
                      type: :TYPE_MESSAGE,
                      label: :LABEL_OPTIONAL,
                      type_name: :"merge.Child",
                      oneof_index: 0
                    },
                    %{
                      name: :text,
                      number: 5,
                      type: :TYPE_STRING,
                      label: :LABEL_OPTIONAL,
                      oneof_index: 0
                    }
                  ],
                  oneof_decl: [%{name: :choice}],
                  extension_range: [%{start: 100, end: 101}],
                  nested_type: [
                    %{
                      name: :ChildrenByNameEntry,
                      options: %{map_entry: true},
                      field: [
                        %{name: :key, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                        %{
                          name: :value,
                          number: 2,
                          type: :TYPE_MESSAGE,
                          label: :LABEL_OPTIONAL,
                          type_name: :"merge.Child"
                        }
                      ]
                    }
                  ]
                },
                %{
                  name: :Child,
                  field: [
                    %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                    %{name: :id, number: 2, type: :TYPE_INT32, label: :LABEL_REQUIRED}
                  ]
                }
              ],
              extension: [
                %{
                  name: :ext_child,
                  number: 100,
                  type: :TYPE_MESSAGE,
                  label: :LABEL_OPTIONAL,
                  type_name: ".merge.Child",
                  extendee: ".merge.Parent"
                }
              ]
            }
          ]
        })

      %{merge_schema: schema}
    end

    test "singular message occurrences merge before required validation", %{
      merge_schema: schema
    } do
      name_only = <<0x0A, 0x01, "a">>
      id_only = <<0x10, 0x7B>>

      bin = [
        <<0x0A, byte_size(name_only)>>,
        name_only,
        <<0x0A, byte_size(id_only)>>,
        id_only
      ]

      assert {:ok, %{child: %{name: "a", id: 123}}} =
               PB.decode(IO.iodata_to_binary(bin), schema, :"merge.Parent")
    end

    test "repeated message occurrences validate independently", %{
      merge_schema: schema
    } do
      name_only = <<0x0A, 0x01, "a">>
      id_only = <<0x10, 0x7B>>

      bin = [
        <<0x12, byte_size(name_only)>>,
        name_only,
        <<0x12, byte_size(id_only)>>,
        id_only
      ]

      assert_error(PB.decode(IO.iodata_to_binary(bin), schema, :"merge.Parent"),
        operation: :decode,
        kind: :missing_required,
        path: [:children, {:index, 0}, :id]
      )
    end

    test "repeated message error path carries the correct non-zero element index", %{
      merge_schema: schema
    } do
      # The element index in the error path is resolved lazily from the captured
      # accumulator list; this guards against an off-by-one at indices past 0.
      valid = <<0x0A, 0x01, "a", 0x10, 0x7B>>
      missing_id = <<0x0A, 0x01, "a">>

      bin = [
        <<0x12, byte_size(valid)>>,
        valid,
        <<0x12, byte_size(valid)>>,
        valid,
        <<0x12, byte_size(missing_id)>>,
        missing_id
      ]

      assert_error(PB.decode(IO.iodata_to_binary(bin), schema, :"merge.Parent"),
        operation: :decode,
        kind: :missing_required,
        path: [:children, {:index, 2}, :id]
      )
    end

    test "same oneof message member merges and different members clear", %{
      merge_schema: schema
    } do
      name_only = <<0x0A, 0x01, "a">>
      id_only = <<0x10, 0x7B>>
      text = "reset"

      merged_same_member = [
        <<0x22, byte_size(name_only)>>,
        name_only,
        <<0x22, byte_size(id_only)>>,
        id_only
      ]

      assert {:ok, %{choice: {:kid, %{name: "a", id: 123}}}} =
               PB.decode(IO.iodata_to_binary(merged_same_member), schema, :"merge.Parent")

      cleared_by_other_member = [
        <<0x22, byte_size(name_only)>>,
        name_only,
        <<0x2A, byte_size(text)>>,
        text,
        <<0x22, byte_size(id_only)>>,
        id_only
      ]

      assert {:ok, %{choice: {:kid, %{id: 123}}}} =
               PB.decode(
                 IO.iodata_to_binary(cleared_by_other_member),
                 schema,
                 :"merge.Parent"
               )
    end

    test "singular message extension occurrences merge before required validation", %{
      merge_schema: schema
    } do
      name_only = <<0x0A, 0x01, "a">>
      id_only = <<0x10, 0x7B>>

      tag = PB.Wire.encode_tag(100, 2)

      bin = [
        tag,
        PB.Wire.encode_varint(byte_size(name_only)),
        name_only,
        tag,
        PB.Wire.encode_varint(byte_size(id_only)),
        id_only
      ]

      extensions = :__extensions__

      assert {:ok,
              %{
                ^extensions => %{
                  :"merge.ext_child" => %{name: "a", id: 123}
                }
              }} = PB.decode(IO.iodata_to_binary(bin), schema, :"merge.Parent")
    end

    test "unknown fields keep wire order after singular message merge", %{
      merge_schema: schema
    } do
      id_and_unknown = <<0x10, 0x7B, 0x48, 0x01>>
      unknown_only = <<0x48, 0x02>>

      bin = [
        <<0x0A, byte_size(id_and_unknown)>>,
        id_and_unknown,
        <<0x0A, byte_size(unknown_only)>>,
        unknown_only
      ]

      unknowns = :__unknown_fields__

      assert {:ok,
              %{
                child: %{
                  ^unknowns => [
                    %PB.UnknownField{number: 9, wire_type: 0, raw: <<0x48, 0x01>>},
                    %PB.UnknownField{number: 9, wire_type: 0, raw: <<0x48, 0x02>>}
                  ],
                  id: 123
                }
              }} = PB.decode(IO.iodata_to_binary(bin), schema, :"merge.Parent")
    end

    test "implicit scalar default occurrence overwrites and elides final value", %{schema: schema} do
      assert {:ok, %{}} = PB.decode(<<0x10, 0x05, 0x10, 0x00>>, schema, :"test.Person")
    end

    test "duplicate map keys keep the last entry", %{schema: schema} do
      first = <<0x0A, 0x01, "a", 0x10, 0x01>>
      second = <<0x0A, 0x01, "a", 0x10, 0x02>>

      bin = [
        <<0x4A, byte_size(first)>>,
        first,
        <<0x4A, byte_size(second)>>,
        second
      ]

      assert {:ok, %{tags: %{"a" => 2}}} =
               PB.decode(IO.iodata_to_binary(bin), schema, :"test.Person")
    end

    test "duplicate map keys collapse before message value required validation", %{
      merge_schema: schema
    } do
      name_only = <<0x0A, 0x01, "a">>
      id_only = <<0x10, 0x7B>>

      first = <<0x0A, 0x01, "a", 0x12, byte_size(name_only), name_only::binary>>
      second = <<0x0A, 0x01, "a", 0x12, byte_size(id_only), id_only::binary>>

      bin = [
        <<0x1A, byte_size(first)>>,
        first,
        <<0x1A, byte_size(second)>>,
        second
      ]

      assert {:ok, %{children_by_name: %{"a" => %{id: 123}}}} =
               PB.decode(IO.iodata_to_binary(bin), schema, :"merge.Parent")
    end

    test "map entry message values merge inside one entry", %{
      merge_schema: schema
    } do
      name_only = <<0x0A, 0x01, "a">>
      id_only = <<0x10, 0x7B>>

      entry =
        <<0x0A, 0x01, "a", 0x12, byte_size(name_only), name_only::binary, 0x12,
          byte_size(id_only), id_only::binary>>

      bin = [<<0x1A, byte_size(entry)>>, entry]

      assert {:ok, %{children_by_name: %{"a" => %{name: "a", id: 123}}}} =
               PB.decode(IO.iodata_to_binary(bin), schema, :"merge.Parent")
    end

    test "duplicate map keys validate the winning message value", %{
      merge_schema: schema
    } do
      id_only = <<0x10, 0x7B>>
      name_only = <<0x0A, 0x01, "a">>

      first = <<0x0A, 0x01, "a", 0x12, byte_size(id_only), id_only::binary>>
      second = <<0x0A, 0x01, "a", 0x12, byte_size(name_only), name_only::binary>>

      bin = [
        <<0x1A, byte_size(first)>>,
        first,
        <<0x1A, byte_size(second)>>,
        second
      ]

      assert_error(PB.decode(IO.iodata_to_binary(bin), schema, :"merge.Parent"),
        operation: :decode,
        kind: :missing_required,
        path: [:children_by_name, {:key, "a"}, :id]
      )
    end
  end

  # ── Full round-trip ────────────────────────────────────────────────

  test "full person round-trip", %{person_decoder: decoder} do
    data = %{
      name: "Alice",
      id: 42,
      phones: [%{number: "+1234567890"}],
      role: :ADMIN,
      scores: [100, 95, 88],
      companion: {:pet, %{name: "Rex"}},
      tags: %{"team" => 1, "level" => 5}
    }

    {:ok, decoded} = assert_decode_roundtrip_consistent(decoder, data)

    assert decoded.name == "Alice"
    assert decoded.id == 42
    assert length(decoded.phones) == 1
    assert hd(decoded.phones).number == "+1234567890"
    assert decoded.role == :ADMIN
    assert decoded.scores == [100, 95, 88]
    assert decoded.companion == {:pet, %{name: "Rex"}}
    assert decoded.tags == %{"team" => 1, "level" => 5}
  end

  # ── Empty message ──────────────────────────────────────────────────

  test "generated decoder populates implicit defaults for empty message", %{
    person_decoder: decoder
  } do
    {:ok, decoded} = assert_decode_roundtrip_consistent(decoder, %{})

    assert decoded == %{name: "", id: 0, phones: [], role: :UNKNOWN, scores: [], tags: %{}}
  end

  # ── Unknown message ────────────────────────────────────────────────

  test "unknown message returns error", %{schema: schema} do
    assert_error(PB.encode(%{}, schema, :"no.Such"),
      operation: :encode,
      kind: :unknown_message,
      message_name: :"no.Such",
      name: :"no.Such"
    )

    assert_error(PB.decode(<<>>, schema, :"no.Such"),
      operation: :decode,
      kind: :unknown_message,
      message_name: :"no.Such",
      name: :"no.Such"
    )
  end
end

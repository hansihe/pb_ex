defmodule PB.DescriptorRuntimeTest do
  use ExUnit.Case

  import PB.TestSupport.Assertions

  alias PB.TestSupport.Fixtures

  setup_all do
    %{schema: PB.compile(Fixtures.person_descriptor_set())}
  end

  # ── Bootstrap / load ───────────────────────────────────────────────

  describe "load from protoc image" do
    @tag :protoc
    test "load and compile a protoc-generated descriptor set" do
      proto = """
      syntax = "proto3";
      package loadtest;
      message Greeting {
        string text = 1;
        int32 count = 2;
      }
      """

      tmp = System.tmp_dir!()
      proto_path = Path.join(tmp, "loadtest.proto")
      desc_path = Path.join(tmp, "loadtest.binpb")
      File.write!(proto_path, proto)

      {_, 0} =
        System.cmd("protoc", [
          "--descriptor_set_out=#{desc_path}",
          "--proto_path=#{tmp}",
          proto_path
        ])

      bin = File.read!(desc_path)
      {:ok, descriptor_set} = PB.decode_descriptor_set(bin)

      assert is_list(descriptor_set[:file])
      file = hd(descriptor_set[:file])
      assert file[:package] == "loadtest"
      assert file[:syntax] == "proto3"

      schema = PB.compile(descriptor_set)
      {:ok, encoded} = PB.encode(%{text: "hi", count: 7}, schema, :"loadtest.Greeting")

      {:ok, decoded} =
        PB.decode(IO.iodata_to_binary(encoded), schema, :"loadtest.Greeting")

      assert decoded == %{text: "hi", count: 7}
    end
  end

  describe "message name metadata" do
    test "decode omits message-name metadata by default", %{schema: schema} do
      {:ok, decoded} = PB.decode(<<>>, schema, :"test.Person")

      refute Map.has_key?(decoded, :__message_name__)
    end

    test "decode can annotate only the root message", %{schema: schema} do
      {:ok, encoded} =
        PB.encode(
          %{
            name: "Alice",
            phones: [%{number: "+1234567890"}]
          },
          schema,
          :"test.Person"
        )

      {:ok, decoded} =
        PB.decode(IO.iodata_to_binary(encoded), schema, :"test.Person", message_names: :root)

      assert decoded[:__message_name__] == :"test.Person"
      refute Map.has_key?(hd(decoded.phones), :__message_name__)
    end

    test "encode accepts matching message-name metadata", %{schema: schema} do
      data = %{__message_name__: :"test.Person", name: "Alice"}

      assert {:ok, _iodata} = PB.encode(data, schema, :"test.Person")
    end

    test "encode rejects mismatched message-name metadata", %{schema: schema} do
      key = :__message_name__

      assert_error(PB.encode(%{key => :"test.PhoneNumber"}, schema, :"test.Person"),
        operation: :encode,
        kind: :message_name_mismatch,
        message_name: :"test.Person",
        path: [key],
        expected: :"test.Person",
        got: :"test.PhoneNumber"
      )
    end
  end

  describe "decode with defaults: true" do
    setup do
      descriptor_set = %{
        file: [
          %{
            name: "defaults_test.proto",
            package: :dtest,
            syntax: :proto3,
            message_type: [
              %{
                name: :Scalars,
                field: [
                  %{name: :f_double, number: 1, type: :TYPE_DOUBLE, label: :LABEL_OPTIONAL},
                  %{name: :f_float, number: 2, type: :TYPE_FLOAT, label: :LABEL_OPTIONAL},
                  %{name: :f_int32, number: 3, type: :TYPE_INT32, label: :LABEL_OPTIONAL},
                  %{name: :f_int64, number: 4, type: :TYPE_INT64, label: :LABEL_OPTIONAL},
                  %{name: :f_uint32, number: 5, type: :TYPE_UINT32, label: :LABEL_OPTIONAL},
                  %{name: :f_uint64, number: 6, type: :TYPE_UINT64, label: :LABEL_OPTIONAL},
                  %{name: :f_sint32, number: 7, type: :TYPE_SINT32, label: :LABEL_OPTIONAL},
                  %{name: :f_sint64, number: 8, type: :TYPE_SINT64, label: :LABEL_OPTIONAL},
                  %{name: :f_fixed32, number: 9, type: :TYPE_FIXED32, label: :LABEL_OPTIONAL},
                  %{name: :f_fixed64, number: 10, type: :TYPE_FIXED64, label: :LABEL_OPTIONAL},
                  %{name: :f_sfixed32, number: 11, type: :TYPE_SFIXED32, label: :LABEL_OPTIONAL},
                  %{name: :f_sfixed64, number: 12, type: :TYPE_SFIXED64, label: :LABEL_OPTIONAL},
                  %{name: :f_bool, number: 13, type: :TYPE_BOOL, label: :LABEL_OPTIONAL},
                  %{name: :f_string, number: 14, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                  %{name: :f_bytes, number: 15, type: :TYPE_BYTES, label: :LABEL_OPTIONAL},
                  %{
                    name: :f_enum,
                    number: 16,
                    type: :TYPE_ENUM,
                    label: :LABEL_OPTIONAL,
                    type_name: :"dtest.Color"
                  }
                ]
              },
              %{
                name: :WithRepeated,
                field: [
                  %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                  %{name: :nums, number: 2, type: :TYPE_INT32, label: :LABEL_REPEATED},
                  %{
                    name: :items,
                    number: 3,
                    type: :TYPE_MESSAGE,
                    label: :LABEL_REPEATED,
                    type_name: :"dtest.Item"
                  }
                ]
              },
              %{
                name: :WithMap,
                field: [
                  %{name: :title, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                  %{
                    name: :labels,
                    number: 2,
                    type: :TYPE_MESSAGE,
                    label: :LABEL_REPEATED,
                    type_name: :"dtest.WithMap.LabelsEntry"
                  }
                ],
                nested_type: [
                  %{
                    name: :LabelsEntry,
                    options: %{map_entry: true},
                    field: [
                      %{name: :key, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                      %{name: :value, number: 2, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
                    ]
                  }
                ]
              },
              %{
                name: :WithOneof,
                field: [
                  %{name: :id, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL},
                  %{
                    name: :email,
                    number: 2,
                    type: :TYPE_STRING,
                    label: :LABEL_OPTIONAL,
                    oneof_index: 0
                  },
                  %{
                    name: :phone,
                    number: 3,
                    type: :TYPE_STRING,
                    label: :LABEL_OPTIONAL,
                    oneof_index: 0
                  }
                ],
                oneof_decl: [%{name: :contact}]
              },
              %{
                name: :WithNested,
                field: [
                  %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                  %{
                    name: :inner,
                    number: 2,
                    type: :TYPE_MESSAGE,
                    label: :LABEL_OPTIONAL,
                    type_name: :"dtest.Item"
                  }
                ]
              },
              %{
                name: :Item,
                field: [
                  %{name: :value, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                  %{name: :count, number: 2, type: :TYPE_INT32, label: :LABEL_OPTIONAL}
                ]
              }
            ],
            enum_type: [
              %{
                name: :Color,
                value: [
                  %{name: :RED, number: 0},
                  %{name: :GREEN, number: 1},
                  %{name: :BLUE, number: 2}
                ]
              }
            ]
          }
        ]
      }

      %{schema: PB.compile(descriptor_set)}
    end

    test "empty message gets all scalar defaults", %{schema: schema} do
      {:ok, decoded} = PB.decode(<<>>, schema, :"dtest.Scalars", defaults: true)

      assert decoded == %{
               f_double: 0.0,
               f_float: 0.0,
               f_int32: 0,
               f_int64: 0,
               f_uint32: 0,
               f_uint64: 0,
               f_sint32: 0,
               f_sint64: 0,
               f_fixed32: 0,
               f_fixed64: 0,
               f_sfixed32: 0,
               f_sfixed64: 0,
               f_bool: false,
               f_string: "",
               f_bytes: "",
               f_enum: :RED
             }
    end

    test "set fields are not overridden by defaults", %{schema: schema} do
      {:ok, encoded} =
        PB.encode(%{f_int32: 42, f_string: "hello", f_bool: true}, schema, :"dtest.Scalars")

      {:ok, decoded} =
        PB.decode(IO.iodata_to_binary(encoded), schema, :"dtest.Scalars", defaults: true)

      assert decoded.f_int32 == 42
      assert decoded.f_string == "hello"
      assert decoded.f_bool == true
      # unset fields still get defaults
      assert decoded.f_double == 0.0
      assert decoded.f_uint64 == 0
    end

    test "repeated fields default to empty list", %{schema: schema} do
      {:ok, decoded} = PB.decode(<<>>, schema, :"dtest.WithRepeated", defaults: true)

      assert decoded == %{name: "", nums: [], items: []}
    end

    test "map fields default to empty map", %{schema: schema} do
      {:ok, decoded} = PB.decode(<<>>, schema, :"dtest.WithMap", defaults: true)

      assert decoded == %{title: "", labels: %{}}
    end

    test "oneof fields are not populated with defaults", %{schema: schema} do
      {:ok, decoded} = PB.decode(<<>>, schema, :"dtest.WithOneof", defaults: true)

      assert decoded == %{id: 0}
      refute Map.has_key?(decoded, :contact)
      refute Map.has_key?(decoded, :email)
      refute Map.has_key?(decoded, :phone)
    end

    test "singular message fields are not populated", %{schema: schema} do
      {:ok, decoded} = PB.decode(<<>>, schema, :"dtest.WithNested", defaults: true)

      assert decoded == %{name: ""}
      refute Map.has_key?(decoded, :inner)
    end

    test "nested messages get defaults when present", %{schema: schema} do
      {:ok, encoded} =
        PB.encode(%{name: "outer", inner: %{value: "hi"}}, schema, :"dtest.WithNested")

      {:ok, decoded} =
        PB.decode(IO.iodata_to_binary(encoded), schema, :"dtest.WithNested", defaults: true)

      assert decoded.name == "outer"
      assert decoded.inner == %{value: "hi", count: 0}
    end

    test "without defaults option, behavior is unchanged", %{schema: schema} do
      {:ok, decoded} = PB.decode(<<>>, schema, :"dtest.Scalars")
      assert decoded == %{}

      {:ok, decoded} = PB.decode(<<>>, schema, :"dtest.WithRepeated")
      assert decoded == %{}
    end
  end
end

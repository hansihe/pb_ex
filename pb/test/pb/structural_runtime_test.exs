defmodule PB.StructuralRuntimeTest do
  use ExUnit.Case

  alias PB.TestSupport.Fixtures

  setup_all do
    %{schema: PB.compile(Fixtures.person_descriptor_set())}
  end

  # ── T10 - Structural / multi-file ───────────────────────────────────

  describe "T10 - structural" do
    test "multiple files in a descriptor set" do
      desc = %{
        file: [
          %{
            name: "a.proto",
            package: :a,
            syntax: :proto3,
            message_type: [
              %{
                name: :Msg,
                field: [%{name: :text, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}]
              }
            ],
            enum_type: []
          },
          %{
            name: "b.proto",
            package: :b,
            syntax: :proto3,
            message_type: [
              %{
                name: :Msg,
                field: [%{name: :count, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL}]
              }
            ],
            enum_type: []
          }
        ]
      }

      schema = PB.compile(desc)
      assert Map.has_key?(schema.messages, :"a.Msg")
      assert Map.has_key?(schema.messages, :"b.Msg")

      {:ok, bin_a} = PB.encode(%{text: "hello"}, schema, :"a.Msg")
      {:ok, dec_a} = PB.decode(IO.iodata_to_binary(bin_a), schema, :"a.Msg")
      assert dec_a == %{text: "hello"}

      {:ok, bin_b} = PB.encode(%{count: 5}, schema, :"b.Msg")
      {:ok, dec_b} = PB.decode(IO.iodata_to_binary(bin_b), schema, :"b.Msg")
      assert dec_b == %{count: 5}
    end

    test "cross-package type references" do
      desc = %{
        file: [
          %{
            name: "base.proto",
            package: :base,
            syntax: :proto3,
            message_type: [
              %{
                name: :Inner,
                field: [%{name: :val, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL}]
              }
            ],
            enum_type: []
          },
          %{
            name: "outer.proto",
            package: :outer,
            syntax: :proto3,
            message_type: [
              %{
                name: :Outer,
                field: [
                  %{
                    name: :inner,
                    number: 1,
                    type: :TYPE_MESSAGE,
                    label: :LABEL_OPTIONAL,
                    type_name: :"base.Inner"
                  }
                ]
              }
            ],
            enum_type: []
          }
        ]
      }

      schema = PB.compile(desc)
      data = %{inner: %{val: 42}}
      {:ok, bin} = PB.encode(data, schema, :"outer.Outer")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), schema, :"outer.Outer")
      assert decoded == %{inner: %{val: 42}}
    end

    test "non-map-entry nested messages" do
      desc = %{
        file: [
          %{
            name: "nest.proto",
            package: :nest,
            syntax: :proto3,
            message_type: [
              %{
                name: :Outer,
                field: [
                  %{
                    name: :inner,
                    number: 1,
                    type: :TYPE_MESSAGE,
                    label: :LABEL_OPTIONAL,
                    type_name: :"nest.Outer.Inner"
                  }
                ],
                nested_type: [
                  %{
                    name: :Inner,
                    field: [
                      %{name: :x, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL}
                    ]
                  }
                ]
              }
            ],
            enum_type: []
          }
        ]
      }

      schema = PB.compile(desc)
      data = %{inner: %{x: 7}}
      {:ok, bin} = PB.encode(data, schema, :"nest.Outer")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), schema, :"nest.Outer")
      assert decoded == %{inner: %{x: 7}}
    end

    test "map with int32 keys" do
      desc = %{
        file: [
          %{
            name: "imap.proto",
            package: :imap,
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
                    type_name: :"imap.Msg.LookupEntry"
                  }
                ],
                nested_type: [
                  %{
                    name: :LookupEntry,
                    options: %{map_entry: true},
                    field: [
                      %{name: :key, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL},
                      %{name: :value, number: 2, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
                    ]
                  }
                ]
              }
            ],
            enum_type: []
          }
        ]
      }

      schema = PB.compile(desc)
      data = %{lookup: %{1 => "one", 2 => "two"}}
      {:ok, bin} = PB.encode(data, schema, :"imap.Msg")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), schema, :"imap.Msg")
      assert decoded.lookup == %{1 => "one", 2 => "two"}
    end

    test "map entries default missing keys and values" do
      desc = %{
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
      }

      schema = PB.compile(desc)

      # Outer field 1 length-delimited map entry, inner field 1 key = "a".
      only_key = <<0x0A, 0x03, 0x0A, 0x01, "a">>
      assert {:ok, %{lookup: %{"a" => 0}}} = PB.decode(only_key, schema, :"mdef.Msg")

      # Outer field 1 length-delimited map entry, inner field 2 value = 42.
      only_value = <<0x0A, 0x02, 0x10, 42>>
      assert {:ok, %{lookup: %{"" => 42}}} = PB.decode(only_value, schema, :"mdef.Msg")

      # Duplicate map keys keep the last value on the wire.
      first = <<0x0A, 0x05, 0x0A, 0x01, "a", 0x10, 1>>
      second = <<0x0A, 0x05, 0x0A, 0x01, "a", 0x10, 2>>
      assert {:ok, %{lookup: %{"a" => 2}}} = PB.decode(first <> second, schema, :"mdef.Msg")
    end

    test "map with message values" do
      desc = %{
        file: [
          %{
            name: "mmap.proto",
            package: :mmap,
            syntax: :proto3,
            message_type: [
              %{
                name: :Info,
                field: [
                  %{name: :score, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL}
                ]
              },
              %{
                name: :Msg,
                field: [
                  %{
                    name: :entries,
                    number: 1,
                    type: :TYPE_MESSAGE,
                    label: :LABEL_REPEATED,
                    type_name: :"mmap.Msg.EntriesEntry"
                  }
                ],
                nested_type: [
                  %{
                    name: :EntriesEntry,
                    options: %{map_entry: true},
                    field: [
                      %{name: :key, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                      %{
                        name: :value,
                        number: 2,
                        type: :TYPE_MESSAGE,
                        label: :LABEL_OPTIONAL,
                        type_name: :"mmap.Info"
                      }
                    ]
                  }
                ]
              }
            ],
            enum_type: []
          }
        ]
      }

      schema = PB.compile(desc)
      data = %{entries: %{"alice" => %{score: 100}, "bob" => %{score: 85}}}
      {:ok, bin} = PB.encode(data, schema, :"mmap.Msg")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), schema, :"mmap.Msg")
      assert decoded.entries == %{"alice" => %{score: 100}, "bob" => %{score: 85}}
    end
  end

  # ── T12 - Sint positive values ──────────────────────────────────────

  describe "T12 - sint positive values" do
    @sint_desc %{
      file: [
        %{
          name: "sint.proto",
          package: :si,
          syntax: :proto3,
          message_type: [
            %{
              name: :Msg,
              field: [
                %{name: :s32, number: 1, type: :TYPE_SINT32, label: :LABEL_OPTIONAL},
                %{name: :s64, number: 2, type: :TYPE_SINT64, label: :LABEL_OPTIONAL}
              ]
            }
          ],
          enum_type: []
        }
      ]
    }

    setup do
      %{si: PB.compile(@sint_desc)}
    end

    test "sint32 positive value", %{si: si} do
      {:ok, bin} = PB.encode(%{s32: 100}, si, :"si.Msg")
      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), si, :"si.Msg")
      assert d.s32 == 100
    end

    test "sint32 zero", %{si: si} do
      {:ok, bin} = PB.encode(%{s32: 0}, si, :"si.Msg")
      assert IO.iodata_to_binary(bin) == <<>>

      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), si, :"si.Msg")
      refute Map.has_key?(d, :s32)
    end

    test "sint32 max positive", %{si: si} do
      {:ok, bin} = PB.encode(%{s32: 2_147_483_647}, si, :"si.Msg")
      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), si, :"si.Msg")
      assert d.s32 == 2_147_483_647
    end

    test "sint64 positive value", %{si: si} do
      {:ok, bin} = PB.encode(%{s64: 100_000_000_000}, si, :"si.Msg")
      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), si, :"si.Msg")
      assert d.s64 == 100_000_000_000
    end

    test "sint64 zero", %{si: si} do
      {:ok, bin} = PB.encode(%{s64: 0}, si, :"si.Msg")
      assert IO.iodata_to_binary(bin) == <<>>

      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), si, :"si.Msg")
      refute Map.has_key?(d, :s64)
    end

    test "sint64 max positive", %{si: si} do
      {:ok, bin} = PB.encode(%{s64: 9_223_372_036_854_775_807}, si, :"si.Msg")
      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), si, :"si.Msg")
      assert d.s64 == 9_223_372_036_854_775_807
    end
  end
end

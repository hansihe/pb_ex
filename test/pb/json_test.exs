defmodule PB.JSONTest do
  use ExUnit.Case

  import Bitwise

  defmodule Nested do
    defstruct [:a, :corecursive]
  end

  alias PB.JSON

  # ── Schema covering oneof, map<string,int32>, enum, repeated message ─

  @descriptor_set %{
    file: [
      %{
        name: "test.proto",
        package: :j,
        syntax: :proto3,
        message_type: [
          %{
            name: :Person,
            field: [
              %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
              %{name: :user_id, number: 2, type: :TYPE_INT32, label: :LABEL_OPTIONAL},
              %{
                name: :phones,
                number: 3,
                type: :TYPE_MESSAGE,
                label: :LABEL_REPEATED,
                type_name: :"j.PhoneNumber"
              },
              %{
                name: :role,
                number: 4,
                type: :TYPE_ENUM,
                label: :LABEL_OPTIONAL,
                type_name: :"j.Role"
              },
              %{name: :scores, number: 5, type: :TYPE_INT32, label: :LABEL_REPEATED},
              %{
                name: :pet,
                number: 6,
                type: :TYPE_MESSAGE,
                label: :LABEL_OPTIONAL,
                type_name: :"j.Pet",
                oneof_index: 0
              },
              %{
                name: :fish,
                number: 7,
                type: :TYPE_MESSAGE,
                label: :LABEL_OPTIONAL,
                type_name: :"j.Fish",
                oneof_index: 0
              },
              %{
                name: :tags,
                number: 8,
                type: :TYPE_MESSAGE,
                label: :LABEL_REPEATED,
                type_name: :"j.Person.TagsEntry"
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
              %{name: :ROLE_UNKNOWN, number: 0},
              %{name: :ADMIN, number: 1},
              %{name: :USER, number: 2}
            ]
          }
        ]
      }
    ]
  }

  setup_all do
    %{schema: PB.compile(@descriptor_set)}
  end

  # ── Option validation ───────────────────────────────────────────────

  describe "option validation" do
    test "encode rejects unknown options (incl. the emit_default typo)", %{schema: schema} do
      assert {:error, %PB.OptionError{kind: :unknown_options, options: [:emit_default]}} =
               JSON.to_term(%{}, schema, :"j.Person", emit_default: true)

      assert {:error, %PB.OptionError{operation: :json_encode, message_name: :"j.Person"}} =
               JSON.encode(%{}, schema, :"j.Person", bogus: true)
    end

    test "encode rejects decode-only options", %{schema: schema} do
      assert {:error, %PB.OptionError{kind: :unknown_options, options: [:ignore_unknown]}} =
               JSON.to_term(%{}, schema, :"j.Person", ignore_unknown: true)
    end

    test "encode rejects non-boolean option values", %{schema: schema} do
      assert {:error, %PB.OptionError{kind: :invalid_option, option: :emit_defaults, value: :yes}} =
               JSON.to_term(%{}, schema, :"j.Person", emit_defaults: :yes)
    end

    test "decode rejects unknown and encode-only options", %{schema: schema} do
      assert {:error, %PB.OptionError{kind: :unknown_options, options: [:bogus]}} =
               JSON.from_term(%{}, schema, :"j.Person", bogus: true)

      assert {:error,
              %PB.OptionError{
                kind: :unknown_options,
                options: [:emit_defaults],
                operation: :json_decode
              }} = JSON.from_term(%{}, schema, :"j.Person", emit_defaults: true)
    end

    test "decode rejects non-keyword options", %{schema: schema} do
      assert {:error, %PB.OptionError{kind: :invalid_options, reason: :atom}} =
               JSON.from_term(%{}, schema, :"j.Person", :nope)
    end

    test "valid options still pass through", %{schema: schema} do
      assert {:ok, %{"userId" => 7}} =
               JSON.to_term(%{user_id: 7}, schema, :"j.Person", emit_defaults: false)

      assert {:ok, _} = JSON.from_term(%{"bogus" => 1}, schema, :"j.Person", ignore_unknown: true)
    end
  end

  # ── Field-name conversion ──────────────────────────────────────────

  describe "field names" do
    test "encode emits lowerCamelCase by default", %{schema: schema} do
      {:ok, json} = JSON.to_term(%{user_id: 7, name: "a"}, schema, :"j.Person")
      assert json == %{"name" => "a", "userId" => 7}
    end

    test "use_proto_names emits snake_case", %{schema: schema} do
      {:ok, json} =
        JSON.to_term(%{user_id: 7}, schema, :"j.Person", use_proto_names: true)

      assert json == %{"user_id" => 7}
    end

    test "decode accepts both spellings", %{schema: schema} do
      {:ok, a} = JSON.from_term(%{"userId" => 7}, schema, :"j.Person")
      {:ok, b} = JSON.from_term(%{"user_id" => 7}, schema, :"j.Person")
      assert a == %{user_id: 7}
      assert b == %{user_id: 7}
    end

    test "atom keys in JSON object are accepted", %{schema: schema} do
      {:ok, decoded} = JSON.from_term(%{userId: 7}, schema, :"j.Person")
      assert decoded == %{user_id: 7}
    end
  end

  # ── Round-trip via PB → JSON → PB ─────────────────────────

  test "full person round-trip via JSON", %{schema: schema} do
    data = %{
      name: "Alice",
      user_id: 42,
      phones: [%{number: "+1"}, %{number: "+2"}],
      role: :ADMIN,
      scores: [10, 20, 30],
      companion: {:pet, %{name: "Rex"}},
      tags: %{"a" => 1, "b" => 2}
    }

    {:ok, json} = JSON.encode(data, schema, :"j.Person")
    assert is_binary(json)
    {:ok, back} = JSON.decode(json, schema, :"j.Person")
    assert back == data
  end

  test "JSON shape of round-trip", %{schema: schema} do
    data = %{
      name: "Alice",
      role: :ADMIN,
      scores: [10, 20],
      companion: {:pet, %{name: "Rex"}},
      tags: %{"a" => 1}
    }

    {:ok, json} = JSON.to_term(data, schema, :"j.Person")

    assert json == %{
             "name" => "Alice",
             "role" => "ADMIN",
             "scores" => [10, 20],
             "pet" => %{"name" => "Rex"},
             "tags" => %{"a" => 1}
           }
  end

  # ── Scalars ───────────────────────────────────────────────────────

  describe "scalar types" do
    @scalar_schema %{
      file: [
        %{
          name: "scalars.proto",
          package: :s,
          syntax: :proto3,
          message_type: [
            %{
              name: :Scalars,
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
    }

    setup do
      %{ss: PB.compile(@scalar_schema)}
    end

    test "encode checks values by the same rules as PB.encode", %{ss: ss} do
      for {field, value, kind} <- [
            {:f_int64, "abc", :invalid_value},
            {:f_bool, "yes", :invalid_value},
            {:f_int32, 1 <<< 31, :value_out_of_range},
            {:f_uint64, -1, :value_out_of_range},
            {:f_string, <<0xFF>>, :invalid_value},
            {:f_double, "1.5", :invalid_value}
          ] do
        assert {:error, %PB.ValueError{kind: ^kind, operation: :json_encode}} =
                 JSON.to_term(%{field => value}, ss, :"s.Scalars"),
               inspect({field, value})

        assert {:error, %PB.ValueError{kind: ^kind}} = PB.encode(%{field => value}, ss, :"s.Scalars")
      end
    end

    test "int64/uint64/fixed64/sfixed64/sint64 emit as strings", %{ss: ss} do
      {:ok, json} =
        JSON.to_term(
          %{
            f_int64: 9_999_999_999,
            f_uint64: 18_446_744_073_709_551_615,
            f_fixed64: 1,
            f_sfixed64: -1,
            f_sint64: -42
          },
          ss,
          :"s.Scalars"
        )

      assert json["fInt64"] == "9999999999"
      assert json["fUint64"] == "18446744073709551615"
      assert json["fFixed64"] == "1"
      assert json["fSfixed64"] == "-1"
      assert json["fSint64"] == "-42"
    end

    test "int32/uint32/fixed32/sfixed32/sint32 emit as numbers", %{ss: ss} do
      {:ok, json} =
        JSON.to_term(
          %{
            f_int32: -7,
            f_uint32: 4_294_967_295,
            f_fixed32: 1,
            f_sfixed32: -1,
            f_sint32: -2
          },
          ss,
          :"s.Scalars"
        )

      assert json == %{
               "fInt32" => -7,
               "fUint32" => 4_294_967_295,
               "fFixed32" => 1,
               "fSfixed32" => -1,
               "fSint32" => -2
             }
    end

    test "decoder accepts int64 as number or string", %{ss: ss} do
      {:ok, a} = JSON.from_term(%{"fInt64" => "9999999999"}, ss, :"s.Scalars")
      {:ok, b} = JSON.from_term(%{"fInt64" => 9_999_999_999}, ss, :"s.Scalars")
      assert a == %{f_int64: 9_999_999_999}
      assert b == %{f_int64: 9_999_999_999}
    end

    test "decoder accepts int32 quoted string", %{ss: ss} do
      {:ok, d} = JSON.from_term(%{"fInt32" => "-7"}, ss, :"s.Scalars")
      assert d == %{f_int32: -7}
    end

    test "decoder accepts exponent notation for ints", %{ss: ss} do
      {:ok, d} = JSON.from_term(%{"fInt32" => "1e2"}, ss, :"s.Scalars")
      assert d == %{f_int32: 100}
    end

    test "decoder rejects out-of-range int", %{ss: ss} do
      assert {:error, %PB.ValueError{operation: :json_decode, kind: :value_out_of_range}} =
               JSON.from_term(%{"fInt32" => 0x80000000}, ss, :"s.Scalars")
    end

    test "decoder rejects fractional value for int", %{ss: ss} do
      assert {:error, %PB.ValueError{operation: :json_decode, kind: :invalid_value}} =
               JSON.from_term(%{"fInt32" => 1.5}, ss, :"s.Scalars")
    end

    test "decoder accepts whole-number float for int", %{ss: ss} do
      {:ok, d} = JSON.from_term(%{"fInt32" => 5.0}, ss, :"s.Scalars")
      assert d == %{f_int32: 5}
    end

    test "decoder accepts large int64 as an exact integer literal", %{ss: ss} do
      # OTP :json decodes integer literals as exact bignums, so a bare int64 max
      # round-trips losslessly without needing quotes.
      {:ok, d} = JSON.from_term(%{"fInt64" => 9_223_372_036_854_775_807}, ss, :"s.Scalars")
      assert d == %{f_int64: 9_223_372_036_854_775_807}
    end

    test "decoder rejects float-form 64-bit int beyond the 2^53 safe range", %{ss: ss} do
      # 1.0e16 is well inside int64 range but past 2^53, so a float can no longer
      # carry the exact value; the canonical form for such a value is a string.
      assert {:error, %PB.ValueError{operation: :json_decode, kind: :invalid_value}} =
               JSON.from_term(%{"fInt64" => 1.0e16}, ss, :"s.Scalars")

      assert {:error, %PB.ValueError{operation: :json_decode, kind: :invalid_value}} =
               JSON.from_term(%{"fUint64" => 1.0e16}, ss, :"s.Scalars")
    end

    test "decoder rejects float-form 64-bit int that rounds out of range", %{ss: ss} do
      # 9.223...e18 rounds up to 2^63, just past int64 max → genuine range error.
      assert {:error, %PB.ValueError{operation: :json_decode, kind: :value_out_of_range}} =
               JSON.from_term(%{"fInt64" => 9.223372036854776e18}, ss, :"s.Scalars")
    end

    test "decoder still accepts the same large 64-bit value as a string", %{ss: ss} do
      {:ok, d} = JSON.from_term(%{"fInt64" => "9223372036854775807"}, ss, :"s.Scalars")
      assert d == %{f_int64: 9_223_372_036_854_775_807}
    end

    test "bool round-trip", %{ss: ss} do
      {:ok, json} = JSON.to_term(%{f_bool: true}, ss, :"s.Scalars")
      assert json == %{"fBool" => true}
      assert {:ok, %{f_bool: true}} = JSON.from_term(json, ss, :"s.Scalars")
    end

    test "bool decoder rejects non-bool", %{ss: ss} do
      assert {:error, %PB.ValueError{operation: :json_decode, kind: :invalid_value}} =
               JSON.from_term(%{"fBool" => "true"}, ss, :"s.Scalars")
    end

    test "bytes encode as base64 and decode back", %{ss: ss} do
      {:ok, json} = JSON.to_term(%{f_bytes: <<0, 1, 2, 255>>}, ss, :"s.Scalars")
      assert json == %{"fBytes" => "AAEC/w=="}
      assert {:ok, %{f_bytes: <<0, 1, 2, 255>>}} = JSON.from_term(json, ss, :"s.Scalars")
    end

    test "bytes decoder accepts URL-safe base64 without padding", %{ss: ss} do
      assert {:ok, %{f_bytes: <<0xFB, 0xFF, 0xBF>>}} =
               JSON.from_term(%{"fBytes" => "-_-_"}, ss, :"s.Scalars")
    end

    test "double encode/decode", %{ss: ss} do
      {:ok, json} = JSON.to_term(%{f_double: 3.5}, ss, :"s.Scalars")
      assert json == %{"fDouble" => 3.5}
      assert {:ok, %{f_double: 3.5}} = JSON.from_term(json, ss, :"s.Scalars")
    end

    test "negative zero floats are emitted like the wire codec", %{ss: ss} do
      data = %{f_double: -0.0, f_float: -0.0}

      assert {:ok, wire} = PB.encode(data, ss, :"s.Scalars")
      assert byte_size(wire) > 0
      assert {:ok, decoded} = PB.decode(wire, ss, :"s.Scalars")
      assert decoded.f_double === -0.0
      assert decoded.f_float === -0.0

      assert {:ok, json} = JSON.to_term(data, ss, :"s.Scalars")
      assert Map.has_key?(json, "fDouble")
      assert Map.has_key?(json, "fFloat")
      assert json["fDouble"] === -0.0
      assert json["fFloat"] === -0.0
    end

    test "double NaN/Infinity/-Infinity as strings", %{ss: ss} do
      {:ok, j1} = JSON.to_term(%{f_double: :nan}, ss, :"s.Scalars")
      {:ok, j2} = JSON.to_term(%{f_double: :infinity}, ss, :"s.Scalars")
      {:ok, j3} = JSON.to_term(%{f_double: :negative_infinity}, ss, :"s.Scalars")
      assert j1 == %{"fDouble" => "NaN"}
      assert j2 == %{"fDouble" => "Infinity"}
      assert j3 == %{"fDouble" => "-Infinity"}

      assert {:ok, %{f_double: :nan}} = JSON.from_term(j1, ss, :"s.Scalars")
      assert {:ok, %{f_double: :infinity}} = JSON.from_term(j2, ss, :"s.Scalars")
      assert {:ok, %{f_double: :negative_infinity}} = JSON.from_term(j3, ss, :"s.Scalars")
    end

    test "double accepts numeric string", %{ss: ss} do
      {:ok, %{f_double: 1.5}} = JSON.from_term(%{"fDouble" => "1.5"}, ss, :"s.Scalars")
    end

    test "float just past single-precision max is rejected", %{ss: ss} do
      assert {:error, %PB.ValueError{kind: :value_out_of_range}} =
               JSON.from_term(%{"fFloat" => 3.502823e38}, ss, :"s.Scalars")

      assert {:error, %PB.ValueError{kind: :value_out_of_range}} =
               JSON.from_term(%{"fFloat" => -3.502823e38}, ss, :"s.Scalars")
    end

    test "float at the single-precision max is accepted", %{ss: ss} do
      # 3.4028234663852886e38 is the IEEE 754 finite max for binary32.
      assert {:ok, %{f_float: 3.4028234663852886e38}} =
               JSON.from_term(%{"fFloat" => 3.4028234663852886e38}, ss, :"s.Scalars")
    end

    test "float infinity is not range-checked", %{ss: ss} do
      assert {:ok, %{f_float: :infinity}} =
               JSON.from_term(%{"fFloat" => "Infinity"}, ss, :"s.Scalars")

      assert {:ok, %{f_float: :negative_infinity}} =
               JSON.from_term(%{"fFloat" => "-Infinity"}, ss, :"s.Scalars")
    end

    test "double accepts values beyond single-precision range", %{ss: ss} do
      # TYPE_DOUBLE has IEEE binary64 range; values that would overflow
      # binary32 must still decode successfully here.
      assert {:ok, %{f_double: 1.0e100}} =
               JSON.from_term(%{"fDouble" => 1.0e100}, ss, :"s.Scalars")
    end

    test "float rejects integer values beyond single-precision range", %{ss: ss} do
      # JSON integers stay as Erlang integers; the range guard must still
      # fire via `abs(integer) > @float32_max`.
      huge = 1_000_000_000_000_000_000_000_000_000_000_000_000_000

      assert {:error, %PB.ValueError{kind: :value_out_of_range}} =
               JSON.from_term(%{"fFloat" => huge}, ss, :"s.Scalars")
    end
  end

  # ── Enums ─────────────────────────────────────────────────────────

  describe "enums" do
    test "encode as string by default", %{schema: schema} do
      {:ok, json} = JSON.to_term(%{role: :ADMIN}, schema, :"j.Person")
      assert json == %{"role" => "ADMIN"}
    end

    test "encode rejects names the enum does not declare", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :unknown_enum_value}} =
               JSON.to_term(%{role: :BOGUS}, schema, :"j.Person")
    end

    test "encode as int with enums_as_ints", %{schema: schema} do
      {:ok, json} = JSON.to_term(%{role: :ADMIN}, schema, :"j.Person", enums_as_ints: true)
      assert json == %{"role" => 1}
    end

    test "decode accepts string name", %{schema: schema} do
      {:ok, %{role: :ADMIN}} = JSON.from_term(%{"role" => "ADMIN"}, schema, :"j.Person")
    end

    test "decode accepts integer", %{schema: schema} do
      {:ok, %{role: :ADMIN}} = JSON.from_term(%{"role" => 1}, schema, :"j.Person")
    end

    test "decode unknown integer keeps int", %{schema: schema} do
      {:ok, %{role: 99}} = JSON.from_term(%{"role" => 99}, schema, :"j.Person")
    end

    test "decode unknown string raises", %{schema: schema} do
      assert {:error, %PB.ValueError{operation: :json_decode, kind: :invalid_enum_value}} =
               JSON.from_term(%{"role" => "BOGUS"}, schema, :"j.Person")
    end

    test "encode integer enum value falls back to int when name missing", %{schema: schema} do
      {:ok, json} = JSON.to_term(%{role: 99}, schema, :"j.Person")
      assert json == %{"role" => 99}
    end

    test "default-value enum (by name or 0) is suppressed in proto3", %{schema: schema} do
      {:ok, j1} = JSON.to_term(%{name: "x", role: :ROLE_UNKNOWN}, schema, :"j.Person")
      {:ok, j2} = JSON.to_term(%{name: "x", role: 0}, schema, :"j.Person")
      assert j1 == %{"name" => "x"}
      assert j2 == %{"name" => "x"}
    end
  end

  describe "ignore_unknown enum string" do
    @ignore_enum_schema %{
      file: [
        %{
          name: "ie.proto",
          package: :ie,
          syntax: :proto3,
          message_type: [
            %{
              name: :M,
              field: [
                %{
                  name: :color,
                  number: 1,
                  type: :TYPE_ENUM,
                  label: :LABEL_OPTIONAL,
                  type_name: :"ie.Color"
                },
                %{
                  name: :colors,
                  number: 2,
                  type: :TYPE_ENUM,
                  label: :LABEL_REPEATED,
                  type_name: :"ie.Color"
                },
                %{
                  name: :by_name,
                  number: 3,
                  type: :TYPE_MESSAGE,
                  label: :LABEL_REPEATED,
                  type_name: :"ie.M.ByNameEntry"
                },
                %{
                  name: :pick_enum,
                  number: 4,
                  type: :TYPE_ENUM,
                  label: :LABEL_OPTIONAL,
                  type_name: :"ie.Color",
                  oneof_index: 0
                },
                %{
                  name: :pick_name,
                  number: 5,
                  type: :TYPE_STRING,
                  label: :LABEL_OPTIONAL,
                  oneof_index: 0
                }
              ],
              oneof_decl: [%{name: :pick}],
              nested_type: [
                %{
                  name: :ByNameEntry,
                  options: %{map_entry: true},
                  field: [
                    %{name: :key, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                    %{
                      name: :value,
                      number: 2,
                      type: :TYPE_ENUM,
                      label: :LABEL_OPTIONAL,
                      type_name: :"ie.Color"
                    }
                  ]
                }
              ]
            }
          ],
          enum_type: [
            %{
              name: :Color,
              value: [
                %{name: :COLOR_UNKNOWN, number: 0},
                %{name: :RED, number: 1},
                %{name: :GREEN, number: 2}
              ]
            }
          ]
        }
      ]
    }

    setup do
      %{ies: PB.compile(@ignore_enum_schema)}
    end

    test "singular unknown string is dropped", %{ies: ies} do
      {:ok, decoded} =
        JSON.from_term(%{"color" => "MAUVE"}, ies, :"ie.M", ignore_unknown: true)

      assert decoded == %{}
    end

    test "singular known string still decodes", %{ies: ies} do
      {:ok, decoded} =
        JSON.from_term(%{"color" => "RED"}, ies, :"ie.M", ignore_unknown: true)

      assert decoded == %{color: :RED}
    end

    test "repeated drops unknown entries, keeps knowns", %{ies: ies} do
      {:ok, decoded} =
        JSON.from_term(
          %{"colors" => ["RED", "MAUVE", "GREEN", "TAUPE"]},
          ies,
          :"ie.M",
          ignore_unknown: true
        )

      assert decoded == %{colors: [:RED, :GREEN]}
    end

    test "repeated with all unknown becomes empty list", %{ies: ies} do
      {:ok, decoded} =
        JSON.from_term(%{"colors" => ["MAUVE", "TAUPE"]}, ies, :"ie.M", ignore_unknown: true)

      assert decoded == %{colors: []}
    end

    test "map drops unknown-valued entries", %{ies: ies} do
      {:ok, decoded} =
        JSON.from_term(
          %{"byName" => %{"a" => "RED", "b" => "MAUVE", "c" => "GREEN"}},
          ies,
          :"ie.M",
          ignore_unknown: true
        )

      assert decoded == %{by_name: %{"a" => :RED, "c" => :GREEN}}
    end

    test "default (ignore_unknown false) still rejects unknown string", %{ies: ies} do
      assert {:error, %PB.ValueError{operation: :json_decode, kind: :invalid_enum_value}} =
               JSON.from_term(%{"color" => "MAUVE"}, ies, :"ie.M")
    end

    test "ignore_unknown does not affect integer enum values (open enum keeps int)",
         %{ies: ies} do
      {:ok, decoded} =
        JSON.from_term(%{"color" => 99}, ies, :"ie.M", ignore_unknown: true)

      # proto3 enums are open: unknown integer is preserved.
      assert decoded == %{color: 99}
    end

    test "oneof enum member skipped on unknown string leaves slot unclaimed", %{ies: ies} do
      {:ok, decoded} =
        JSON.from_term(
          %{"pickEnum" => "MAUVE", "pickName" => "fallback"},
          ies,
          :"ie.M",
          ignore_unknown: true
        )

      # pickEnum is skipped → the other oneof member is free to claim the slot.
      assert decoded == %{pick: {:pick_name, "fallback"}}
    end

    test "oneof enum member with known string still claims the slot", %{ies: ies} do
      {:ok, decoded} =
        JSON.from_term(%{"pickEnum" => "RED"}, ies, :"ie.M", ignore_unknown: true)

      assert decoded == %{pick: {:pick_enum, :RED}}
    end
  end

  # ── Repeated, maps, oneofs ────────────────────────────────────────

  test "empty repeated is omitted", %{schema: schema} do
    {:ok, json} = JSON.to_term(%{name: "x", scores: []}, schema, :"j.Person")
    assert json == %{"name" => "x"}
  end

  test "empty map is omitted", %{schema: schema} do
    {:ok, json} = JSON.to_term(%{name: "x", tags: %{}}, schema, :"j.Person")
    assert json == %{"name" => "x"}
  end

  test "oneof emits only the active variant", %{schema: schema} do
    {:ok, json} = JSON.to_term(%{companion: {:pet, %{name: "r"}}}, schema, :"j.Person")
    assert json == %{"pet" => %{"name" => "r"}}
  end

  test "decoder rejects multiple oneof variants", %{schema: schema} do
    assert {:error, %PB.ValueError{operation: :json_decode, kind: :invalid_oneof}} =
             JSON.from_term(
               %{
                 "pet" => %{"name" => "r"},
                 "fish" => %{"species" => "g"}
               },
               schema,
               :"j.Person"
             )
  end

  describe "map fields" do
    @intkey_schema %{
      file: [
        %{
          name: "m.proto",
          package: :m,
          syntax: :proto3,
          message_type: [
            %{
              name: :M,
              field: [
                %{
                  name: :counts,
                  number: 1,
                  type: :TYPE_MESSAGE,
                  label: :LABEL_REPEATED,
                  type_name: :"m.M.CountsEntry"
                }
              ],
              nested_type: [
                %{
                  name: :CountsEntry,
                  options: %{map_entry: true},
                  field: [
                    %{name: :key, number: 1, type: :TYPE_INT64, label: :LABEL_OPTIONAL},
                    %{name: :value, number: 2, type: :TYPE_INT32, label: :LABEL_OPTIONAL}
                  ]
                }
              ]
            }
          ]
        }
      ]
    }

    setup do
      %{ms: PB.compile(@intkey_schema)}
    end

    test "int64 keys are stringified", %{ms: ms} do
      {:ok, json} = JSON.to_term(%{counts: %{1 => 10, 2 => 20}}, ms, :"m.M")
      assert json == %{"counts" => %{"1" => 10, "2" => 20}}
    end

    test "int64 keys are parsed back from strings", %{ms: ms} do
      {:ok, decoded} =
        JSON.from_term(%{"counts" => %{"1" => 10, "2" => 20}}, ms, :"m.M")

      assert decoded == %{counts: %{1 => 10, 2 => 20}}
    end
  end

  # ── null and missing field handling ───────────────────────────────

  test "null leaves field unset", %{schema: schema} do
    {:ok, decoded} =
      JSON.from_term(%{"name" => nil, "userId" => 7, "scores" => nil}, schema, :"j.Person")

    assert decoded == %{user_id: 7}
  end

  test "null inside repeated is rejected", %{schema: schema} do
    assert {:error, %PB.DecodeError{operation: :json_decode, kind: :malformed_json}} =
             JSON.from_term(%{"scores" => [1, nil, 2]}, schema, :"j.Person")
  end

  test "missing fields decode to empty map", %{schema: schema} do
    {:ok, decoded} = JSON.from_term(%{}, schema, :"j.Person")
    assert decoded == %{}
  end

  # ── Unknown field handling ────────────────────────────────────────

  test "unknown field errors by default", %{schema: schema} do
    assert {:error, %PB.ValueError{operation: :json_decode, kind: :unknown_field}} =
             JSON.from_term(%{"bogus" => 1}, schema, :"j.Person")
  end

  test "ignore_unknown skips unknown fields", %{schema: schema} do
    {:ok, decoded} =
      JSON.from_term(%{"bogus" => 1, "name" => "x"}, schema, :"j.Person", ignore_unknown: true)

    assert decoded == %{name: "x"}
  end

  # ── Duplicate field rejection ────────────────────────────────────

  test "duplicate field via differing casing is rejected", %{schema: schema} do
    assert {:error, %PB.DecodeError{operation: :json_decode, kind: :duplicate_field}} =
             JSON.from_term(%{"user_id" => 1, "userId" => 2}, schema, :"j.Person")
  end

  test "duplicate field rejection mentions the proto field name", %{schema: schema} do
    {:error, %PB.DecodeError{details: details}} =
      JSON.from_term(%{"user_id" => 1, "userId" => 2}, schema, :"j.Person")

    assert details.field == :user_id
  end

  test "decode/4 rejects exact-duplicate JSON object keys as malformed_json",
       %{schema: schema} do
    assert {:error,
            %PB.DecodeError{
              operation: :json_decode,
              kind: :malformed_json,
              reason: reason
            }} = JSON.decode(~s({"userId": 1, "userId": 2}), schema, :"j.Person")

    assert reason =~ "duplicate"
    assert reason =~ "userId"
  end

  test "decode/4 maps JSON null to nil consistently with from_term/4",
       %{schema: schema} do
    assert {:ok, %{user_id: 7}} =
             JSON.decode(
               ~s({"name":null,"userId":7,"scores":null}),
               schema,
               :"j.Person"
             )
  end

  describe "decode depth guard" do
    setup do
      %{schema: PB.TestSupport.TestSchema.schema()}
    end

    @recursive_message :"protobuf_test_messages.proto3.TestAllTypesProto3"
    @value :"google.protobuf.Value"
    @struct :"google.protobuf.Struct"
    @list_value :"google.protobuf.ListValue"

    test "decode/4 rejects JSON container nesting past the fixed limit", %{schema: schema} do
      assert {:ok, _} =
               JSON.decode(nested_array_json(100), schema, @value)

      assert {:error,
              %PB.DecodeError{
                operation: :json_decode,
                kind: :malformed_json,
                reason: :max_decode_depth_exceeded
              }} = JSON.decode(nested_array_json(101), schema, @value)
    end

    test "from_term/4 rejects recursive messages past the fixed limit", %{schema: schema} do
      assert {:ok, _} =
               JSON.from_term(nested_recursive_message(100), schema, @recursive_message)

      assert {:error,
              %PB.DecodeError{
                operation: :json_decode,
                kind: :malformed_json,
                reason: :max_decode_depth_exceeded
              }} = JSON.from_term(nested_recursive_message(101), schema, @recursive_message)
    end

    test "from_term/4 rejects deeply nested Value objects and arrays", %{schema: schema} do
      assert {:error,
              %PB.DecodeError{
                operation: :json_decode,
                kind: :malformed_json,
                reason: :max_decode_depth_exceeded
              }} = JSON.from_term(nested_object(101), schema, @value)

      assert {:error,
              %PB.DecodeError{
                operation: :json_decode,
                kind: :malformed_json,
                reason: :max_decode_depth_exceeded
              }} = JSON.from_term(nested_array(101), schema, @value)
    end

    test "from_term/4 rejects deeply nested Struct and ListValue payloads", %{schema: schema} do
      assert {:error,
              %PB.DecodeError{
                operation: :json_decode,
                kind: :malformed_json,
                reason: :max_decode_depth_exceeded
              }} = JSON.from_term(nested_object(102), schema, @struct)

      assert {:error,
              %PB.DecodeError{
                operation: :json_decode,
                kind: :malformed_json,
                reason: :max_decode_depth_exceeded
              }} = JSON.from_term(nested_array(102), schema, @list_value)
    end
  end

  # ── emit_defaults ─────────────────────────────────────────────────

  describe "emit_defaults" do
    test "fills defaults for proto3 implicit-presence scalars", %{schema: schema} do
      {:ok, json} = JSON.to_term(%{}, schema, :"j.Person", emit_defaults: true)

      assert json == %{
               "name" => "",
               "userId" => 0,
               "phones" => [],
               "role" => "ROLE_UNKNOWN",
               "scores" => [],
               "tags" => %{}
             }
    end

    test "does not emit message-typed singulars or oneof members", %{schema: schema} do
      {:ok, json} = JSON.to_term(%{}, schema, :"j.Person", emit_defaults: true)
      refute Map.has_key?(json, "pet")
      refute Map.has_key?(json, "fish")
    end

    test "respects enums_as_ints for default", %{schema: schema} do
      {:ok, json} =
        JSON.to_term(%{}, schema, :"j.Person", emit_defaults: true, enums_as_ints: true)

      assert json["role"] == 0
    end
  end

  # ── proto2 presence ────────────────────────────────────────────────

  describe "proto2 presence" do
    @p2 %{
      file: [
        %{
          name: "p.proto",
          package: :p,
          syntax: :proto2,
          message_type: [
            %{
              name: :M,
              field: [
                %{name: :n, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL}
              ]
            }
          ]
        }
      ]
    }

    setup do
      %{ps: PB.compile(@p2)}
    end

    test "proto2 emits default scalar value when set", %{ps: ps} do
      {:ok, json} = JSON.to_term(%{n: 0}, ps, :"p.M")
      assert json == %{"n" => 0}
    end
  end

  test "required fields are enforced for JSON encode and decode" do
    schema =
      PB.compile(%{
        file: [
          %{
            name: "required.proto",
            package: :reqj,
            syntax: :proto2,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{name: :id, number: 1, type: :TYPE_INT32, label: :LABEL_REQUIRED}
                ]
              },
              %{
                name: :MsgWithRequiredChild,
                field: [
                  %{
                    name: :child,
                    number: 1,
                    type: :TYPE_MESSAGE,
                    label: :LABEL_REQUIRED,
                    type_name: :"reqj.Child"
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

    assert {:error, %PB.ValueError{operation: :json_encode, kind: :missing_required} = error} =
             JSON.to_term(%{}, schema, :"reqj.Msg")

    message = Exception.message(error)
    assert message =~ "missing required field id"

    assert {:error, %PB.ValueError{operation: :json_decode, kind: :missing_required} = error} =
             JSON.from_term(%{}, schema, :"reqj.Msg")

    message = Exception.message(error)
    assert message =~ "missing required field id"

    assert {:ok, %{"id" => 0}} = JSON.to_term(%{id: 0}, schema, :"reqj.Msg")
    assert {:ok, %{id: 0}} = JSON.from_term(%{"id" => 0}, schema, :"reqj.Msg")

    assert {:error,
            %PB.ValueError{
              operation: :json_encode,
              kind: :missing_required,
              path: [:child]
            }} = JSON.to_term(%{child: nil}, schema, :"reqj.MsgWithRequiredChild")

    assert {:error,
            %PB.ValueError{
              operation: :json_decode,
              kind: :missing_required,
              path: [:child]
            }} = JSON.from_term(%{"child" => nil}, schema, :"reqj.MsgWithRequiredChild")

    assert {:ok, %{"child" => %{}}} =
             JSON.to_term(%{child: %{}}, schema, :"reqj.MsgWithRequiredChild")

    assert {:ok, %{child: %{}}} =
             JSON.from_term(%{"child" => %{}}, schema, :"reqj.MsgWithRequiredChild")
  end

  # ── Error cases at top level ──────────────────────────────────────

  test "unknown message returns error", %{schema: schema} do
    assert {:error,
            %PB.SchemaError{
              operation: :json_encode,
              kind: :unknown_message,
              message_name: :"j.Bogus",
              name: :"j.Bogus"
            }} =
             JSON.to_term(%{}, schema, :"j.Bogus")

    assert {:error,
            %PB.SchemaError{
              operation: :json_decode,
              kind: :unknown_message,
              message_name: :"j.Bogus",
              name: :"j.Bogus"
            }} =
             JSON.from_term(%{}, schema, :"j.Bogus")
  end

  test "non-map JSON top-level is malformed", %{schema: schema} do
    assert {:error, %PB.DecodeError{operation: :json_decode, kind: :malformed_json}} =
             JSON.from_term("not a map", schema, :"j.Person")

    assert {:error, %PB.DecodeError{operation: :json_decode, kind: :malformed_json}} =
             JSON.from_term(nil, schema, :"j.Person")
  end

  describe "well-known wrapper types" do
    setup do
      %{schema: PB.TestSupport.TestSchema.schema()}
    end

    test "Int32Value top-level encodes as bare number", %{schema: schema} do
      assert {:ok, 42} = JSON.to_term(%{value: 42}, schema, :"google.protobuf.Int32Value")
      assert {:ok, 0} = JSON.to_term(%{}, schema, :"google.protobuf.Int32Value")
    end

    test "wrapper values are checked like any other field", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :value_out_of_range}} =
               JSON.to_term(%{value: 1 <<< 40}, schema, :"google.protobuf.Int32Value")

      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.to_term(%{value: "yes"}, schema, :"google.protobuf.BoolValue")
    end

    test "Int32Value top-level decodes scalar to %{value: n}", %{schema: schema} do
      assert {:ok, %{value: 42}} = JSON.from_term(42, schema, :"google.protobuf.Int32Value")
    end

    test "Int64Value emits string and parses string back", %{schema: schema} do
      assert {:ok, "9223372036854775807"} =
               JSON.to_term(
                 %{value: 9_223_372_036_854_775_807},
                 schema,
                 :"google.protobuf.Int64Value"
               )

      assert {:ok, %{value: -1}} = JSON.from_term("-1", schema, :"google.protobuf.Int64Value")
    end

    test "BoolValue round-trip", %{schema: schema} do
      assert {:ok, true} = JSON.to_term(%{value: true}, schema, :"google.protobuf.BoolValue")
      assert {:ok, %{value: false}} = JSON.from_term(false, schema, :"google.protobuf.BoolValue")
    end

    test "StringValue round-trip", %{schema: schema} do
      assert {:ok, "hi"} = JSON.to_term(%{value: "hi"}, schema, :"google.protobuf.StringValue")
      assert {:ok, %{value: ""}} = JSON.from_term("", schema, :"google.protobuf.StringValue")
    end

    test "BytesValue uses base64", %{schema: schema} do
      bytes = <<1, 2, 3>>
      assert {:ok, "AQID"} = JSON.to_term(%{value: bytes}, schema, :"google.protobuf.BytesValue")

      assert {:ok, %{value: ^bytes}} =
               JSON.from_term("AQID", schema, :"google.protobuf.BytesValue")
    end

    test "encode accepts bare scalar when the wrappers projection is configured", %{
      schema: schema
    } do
      # The bare-scalar native form is legitimate only when the schema carries the
      # wrappers projection; the frontend converts it to the proto-map before
      # encoding. Without the projection the native form is `%{value: v}`.
      projected =
        PB.Schema.Transform.projections(schema, PB.WellKnownTypes.projections(:wrappers))

      assert {:ok, 7} = JSON.to_term(7, projected, :"google.protobuf.Int32Value")
      assert {:ok, "hi"} = JSON.to_term("hi", projected, :"google.protobuf.StringValue")
    end

    test "FloatValue accepts NaN/Infinity", %{schema: schema} do
      assert {:ok, "NaN"} = JSON.to_term(%{value: :nan}, schema, :"google.protobuf.FloatValue")

      assert {:ok, %{value: :infinity}} =
               JSON.from_term("Infinity", schema, :"google.protobuf.FloatValue")
    end

    test "FloatValue rejects values beyond single-precision range", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :value_out_of_range}} =
               JSON.from_term(3.502823e38, schema, :"google.protobuf.FloatValue")
    end

    test "wrapper field on outer message round-trips", %{schema: schema} do
      # protobuf_test_messages.proto3.TestAllTypesProto3 has optional_int32_wrapper:
      fqn = :"protobuf_test_messages.proto3.TestAllTypesProto3"

      assert {:ok, %{"optionalInt32Wrapper" => 7}} =
               JSON.to_term(%{optional_int32_wrapper: %{value: 7}}, schema, fqn)

      assert {:ok, %{optional_int32_wrapper: %{value: 7}}} =
               JSON.from_term(%{"optionalInt32Wrapper" => 7}, schema, fqn)
    end

    test "wrapper field with default scalar inside still emits", %{schema: schema} do
      fqn = :"protobuf_test_messages.proto3.TestAllTypesProto3"

      assert {:ok, %{"optionalInt32Wrapper" => 0}} =
               JSON.to_term(%{optional_int32_wrapper: %{value: 0}}, schema, fqn)

      assert {:ok, %{"optionalInt32Wrapper" => 0}} =
               JSON.to_term(%{optional_int32_wrapper: %{}}, schema, fqn)
    end

    test "repeated wrappers round-trip", %{schema: schema} do
      fqn = :"protobuf_test_messages.proto3.TestAllTypesProto3"

      assert {:ok, %{"repeatedInt32Wrapper" => [1, 2, 3]}} =
               JSON.to_term(
                 %{repeated_int32_wrapper: [%{value: 1}, %{value: 2}, %{value: 3}]},
                 schema,
                 fqn
               )

      assert {:ok, %{repeated_int32_wrapper: [%{value: 1}, %{value: 2}]}} =
               JSON.from_term(%{"repeatedInt32Wrapper" => [1, 2]}, schema, fqn)
    end

    test "null at wrapper field leaves it unset", %{schema: schema} do
      fqn = :"protobuf_test_messages.proto3.TestAllTypesProto3"

      assert {:ok, decoded} = JSON.from_term(%{"optionalInt32Wrapper" => nil}, schema, fqn)
      refute Map.has_key?(decoded, :optional_int32_wrapper)
    end

    test "top-level nil returns a clean error for every wrapper", %{schema: schema} do
      for fqn <- [
            :"google.protobuf.Int32Value",
            :"google.protobuf.Int64Value",
            :"google.protobuf.UInt32Value",
            :"google.protobuf.UInt64Value",
            :"google.protobuf.DoubleValue",
            :"google.protobuf.FloatValue",
            :"google.protobuf.BoolValue",
            :"google.protobuf.StringValue",
            :"google.protobuf.BytesValue"
          ] do
        assert {:error, %PB.ValueError{operation: :json_encode, kind: :invalid_value}} =
                 JSON.to_term(nil, schema, fqn)

        assert {:error, %PB.ValueError{operation: :json_decode, kind: :invalid_value}} =
                 JSON.from_term(nil, schema, fqn)
      end
    end

    test "DoubleValue handles -Infinity", %{schema: schema} do
      assert {:ok, "-Infinity"} =
               JSON.to_term(%{value: :negative_infinity}, schema, :"google.protobuf.DoubleValue")

      assert {:ok, %{value: :negative_infinity}} =
               JSON.from_term("-Infinity", schema, :"google.protobuf.DoubleValue")
    end

    test "UInt32Value rejects negatives", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :value_out_of_range}} =
               JSON.from_term(-1, schema, :"google.protobuf.UInt32Value")
    end

    test "bool/int zero wrappers encode the default", %{schema: schema} do
      # Falsy bare scalars (via the wrappers projection) still encode to the
      # wrapper's present default rather than being dropped.
      projected =
        PB.Schema.Transform.projections(schema, PB.WellKnownTypes.projections(:wrappers))

      assert {:ok, false} = JSON.to_term(false, projected, :"google.protobuf.BoolValue")
      assert {:ok, 0} = JSON.to_term(0, projected, :"google.protobuf.Int32Value")
      assert {:ok, "0"} = JSON.to_term(0, projected, :"google.protobuf.Int64Value")
    end
  end

  describe "FieldMask" do
    setup do
      %{schema: PB.TestSupport.TestSchema.schema()}
    end

    @field_mask :"google.protobuf.FieldMask"

    test "top-level encode joins paths and camelCases", %{schema: schema} do
      assert {:ok, "fooBar,bazQux"} =
               JSON.to_term(%{paths: ["foo_bar", "baz_qux"]}, schema, @field_mask)
    end

    test "top-level encode of empty paths is the empty string", %{schema: schema} do
      assert {:ok, ""} = JSON.to_term(%{paths: []}, schema, @field_mask)
      assert {:ok, ""} = JSON.to_term(%{}, schema, @field_mask)
    end

    test "top-level decode splits paths and snake_cases", %{schema: schema} do
      assert {:ok, %{paths: ["foo_bar", "baz_qux"]}} =
               JSON.from_term("fooBar,bazQux", schema, @field_mask)
    end

    test "top-level decode of empty string yields no paths", %{schema: schema} do
      assert {:ok, %{paths: []}} = JSON.from_term("", schema, @field_mask)
    end

    test "nested dotted paths pass through unchanged", %{schema: schema} do
      assert {:ok, "user.fooBar"} = JSON.to_term(%{paths: ["user.foo_bar"]}, schema, @field_mask)

      assert {:ok, %{paths: ["user.foo_bar"]}} =
               JSON.from_term("user.fooBar", schema, @field_mask)
    end

    test "encode rejects uppercase in source path", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.to_term(%{paths: ["FooBar"]}, schema, @field_mask)
    end

    test "encode rejects underscore followed by non-lowercase", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.to_term(%{paths: ["foo_3"]}, schema, @field_mask)

      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.to_term(%{paths: ["foo__bar"]}, schema, @field_mask)

      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.to_term(%{paths: ["foo_"]}, schema, @field_mask)
    end

    test "decode rejects underscore in JSON input", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term("foo_bar", schema, @field_mask)
    end

    test "decode rejects non-string", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term(42, schema, @field_mask)

      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term(%{}, schema, @field_mask)

      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term([], schema, @field_mask)
    end

    test "encode rejects non-list paths field", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.to_term(%{paths: "foo_bar"}, schema, @field_mask)
    end

    test "FieldMask as a nested field on a host message round-trips", %{schema: schema} do
      fqn = :"protobuf_test_messages.proto3.TestAllTypesProto3"

      assert {:ok, %{"optionalFieldMask" => "fooBar,baz"}} =
               JSON.to_term(
                 %{optional_field_mask: %{paths: ["foo_bar", "baz"]}},
                 schema,
                 fqn
               )

      assert {:ok, %{optional_field_mask: %{paths: ["foo_bar", "baz"]}}} =
               JSON.from_term(%{"optionalFieldMask" => "fooBar,baz"}, schema, fqn)
    end

    test "preserves digits inside path segments", %{schema: schema} do
      assert {:ok, "foo3,bar9baz"} =
               JSON.to_term(%{paths: ["foo3", "bar9baz"]}, schema, @field_mask)

      assert {:ok, %{paths: ["foo3", "bar9baz"]}} =
               JSON.from_term("foo3,bar9baz", schema, @field_mask)
    end
  end

  describe "Duration" do
    setup do
      %{schema: PB.TestSupport.TestSchema.schema()}
    end

    @duration :"google.protobuf.Duration"

    test "encodes whole seconds with no fractional part", %{schema: schema} do
      assert {:ok, "5s"} = JSON.to_term(%{seconds: 5, nanos: 0}, schema, @duration)
      assert {:ok, "0s"} = JSON.to_term(%{}, schema, @duration)
      assert {:ok, "-1s"} = JSON.to_term(%{seconds: -1, nanos: 0}, schema, @duration)
    end

    test "encodes with 3/6/9 fractional digits depending on precision", %{schema: schema} do
      assert {:ok, "1.500s"} = JSON.to_term(%{seconds: 1, nanos: 500_000_000}, schema, @duration)
      assert {:ok, "1.000001s"} = JSON.to_term(%{seconds: 1, nanos: 1_000}, schema, @duration)
      assert {:ok, "1.000000001s"} = JSON.to_term(%{seconds: 1, nanos: 1}, schema, @duration)
    end

    test "negative duration carries sign on both fields", %{schema: schema} do
      assert {:ok, "-1.500s"} =
               JSON.to_term(%{seconds: -1, nanos: -500_000_000}, schema, @duration)

      assert {:ok, %{seconds: -1, nanos: -500_000_000}} =
               JSON.from_term("-1.500s", schema, @duration)
    end

    test "decodes integer and fractional inputs", %{schema: schema} do
      assert {:ok, %{seconds: 5, nanos: 0}} = JSON.from_term("5s", schema, @duration)
      assert {:ok, %{seconds: 1, nanos: 500_000_000}} = JSON.from_term("1.5s", schema, @duration)

      assert {:ok, %{seconds: 0, nanos: 123_456_789}} =
               JSON.from_term("0.123456789s", schema, @duration)
    end

    test "rejects out-of-range seconds on encode and decode", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :value_out_of_range}} =
               JSON.to_term(%{seconds: 315_576_000_001, nanos: 0}, schema, @duration)

      assert {:error, %PB.ValueError{kind: :value_out_of_range}} =
               JSON.from_term("315576000001s", schema, @duration)
    end

    test "rejects out-of-range nanos on encode", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :value_out_of_range}} =
               JSON.to_term(%{seconds: 0, nanos: 1_000_000_000}, schema, @duration)
    end

    test "rejects mismatched sign between seconds and nanos", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.to_term(%{seconds: 1, nanos: -1}, schema, @duration)

      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.to_term(%{seconds: -1, nanos: 1}, schema, @duration)
    end

    test "decode rejects missing 's' suffix and bad format", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term("5", schema, @duration)

      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term("5.s", schema, @duration)

      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term("abc", schema, @duration)

      for input <- ["5\ns", "1.5\ns", "0.\n5s"] do
        assert {:error, %PB.ValueError{kind: :invalid_value}} =
                 JSON.from_term(input, schema, @duration)
      end
    end

    test "decode rejects explicit '+' prefix (spec allows only '-')", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term("+5s", schema, @duration)
    end

    test "zero seconds with negative nanos round-trips", %{schema: schema} do
      assert {:ok, "-0.500s"} =
               JSON.to_term(%{seconds: 0, nanos: -500_000_000}, schema, @duration)

      assert {:ok, %{seconds: 0, nanos: -500_000_000}} =
               JSON.from_term("-0.500s", schema, @duration)
    end

    test "Duration nested on host message round-trips", %{schema: schema} do
      fqn = :"protobuf_test_messages.proto3.TestAllTypesProto3"

      assert {:ok, %{"optionalDuration" => "1.500s"}} =
               JSON.to_term(%{optional_duration: %{seconds: 1, nanos: 500_000_000}}, schema, fqn)

      assert {:ok, %{optional_duration: %{seconds: 1, nanos: 500_000_000}}} =
               JSON.from_term(%{"optionalDuration" => "1.500s"}, schema, fqn)
    end
  end

  describe "Timestamp" do
    setup do
      %{schema: PB.TestSupport.TestSchema.schema()}
    end

    @timestamp :"google.protobuf.Timestamp"

    test "epoch round-trip", %{schema: schema} do
      assert {:ok, "1970-01-01T00:00:00Z"} = JSON.to_term(%{}, schema, @timestamp)

      assert {:ok, %{seconds: 0, nanos: 0}} =
               JSON.from_term("1970-01-01T00:00:00Z", schema, @timestamp)
    end

    test "encodes with shortest fractional precision (3/6/9)", %{schema: schema} do
      assert {:ok, "1972-01-01T12:00:20.021Z"} =
               JSON.to_term(%{seconds: 63_115_220, nanos: 21_000_000}, schema, @timestamp)

      assert {:ok, "1970-01-01T00:00:00.000001Z"} =
               JSON.to_term(%{seconds: 0, nanos: 1_000}, schema, @timestamp)

      assert {:ok, "1970-01-01T00:00:00.000000001Z"} =
               JSON.to_term(%{seconds: 0, nanos: 1}, schema, @timestamp)
    end

    test "decode accepts timezone offsets and normalises to UTC", %{schema: schema} do
      assert {:ok, %{seconds: 0, nanos: 0}} =
               JSON.from_term("1970-01-01T01:00:00+01:00", schema, @timestamp)

      assert {:ok, %{seconds: 18_000, nanos: 0}} =
               JSON.from_term("1970-01-01T00:00:00-05:00", schema, @timestamp)
    end

    test "decode rejects lowercase t / z (RFC 3339 calendar form requires uppercase)",
         %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term("1970-01-01t00:00:00Z", schema, @timestamp)

      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term("1970-01-01T00:00:00z", schema, @timestamp)
    end

    test "encode rejects negative nanos", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :value_out_of_range}} =
               JSON.to_term(%{seconds: 0, nanos: -1}, schema, @timestamp)
    end

    test "encode rejects out-of-range seconds (year < 0001 or > 9999)", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :value_out_of_range}} =
               JSON.to_term(%{seconds: 253_402_300_800, nanos: 0}, schema, @timestamp)

      assert {:error, %PB.ValueError{kind: :value_out_of_range}} =
               JSON.to_term(%{seconds: -62_135_596_801, nanos: 0}, schema, @timestamp)
    end

    test "decode rejects invalid date components", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term("1970-13-01T00:00:00Z", schema, @timestamp)

      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term("not-a-timestamp", schema, @timestamp)

      for input <- ["1970-01-0\nT00:00:00Z", "1970-01-01T00:00:00.5\nZ"] do
        assert {:error, %PB.ValueError{kind: :invalid_value}} =
                 JSON.from_term(input, schema, @timestamp)
      end
    end

    test "Timestamp nested on host message round-trips", %{schema: schema} do
      fqn = :"protobuf_test_messages.proto3.TestAllTypesProto3"

      assert {:ok, %{"optionalTimestamp" => "2024-01-02T03:04:05Z"}} =
               JSON.to_term(
                 %{optional_timestamp: %{seconds: 1_704_164_645, nanos: 0}},
                 schema,
                 fqn
               )

      assert {:ok, %{optional_timestamp: %{seconds: 1_704_164_645, nanos: 0}}} =
               JSON.from_term(%{"optionalTimestamp" => "2024-01-02T03:04:05Z"}, schema, fqn)
    end

    test "non-string input rejected", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term(42, schema, @timestamp)
    end

    test "leap-second input normalises to the next minute", %{schema: schema} do
      # 1993-06-30T23:59:60Z -> 1993-07-01T00:00:00Z (Unix seconds 741484800)
      assert {:ok, %{seconds: 741_484_800, nanos: 0}} =
               JSON.from_term("1993-06-30T23:59:60Z", schema, @timestamp)
    end

    test "fractional > 9 digits rejected", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term("1970-01-01T00:00:00.1234567890Z", schema, @timestamp)
    end
  end

  describe "NullValue" do
    setup do
      %{schema: PB.TestSupport.TestSchema.schema()}
    end

    @p3 :"protobuf_test_messages.proto3.TestAllTypesProto3"

    test "JSON null on singular non-oneof NullValue sets the field", %{schema: schema} do
      assert {:ok, %{optional_null_value: :NULL_VALUE}} =
               JSON.from_term(%{"optionalNullValue" => nil}, schema, @p3)
    end

    test "JSON \"NULL_VALUE\" string on singular NullValue is accepted", %{schema: schema} do
      assert {:ok, %{optional_null_value: :NULL_VALUE}} =
               JSON.from_term(%{"optionalNullValue" => "NULL_VALUE"}, schema, @p3)
    end

    test "JSON null on oneof NullValue member claims the slot", %{schema: schema} do
      assert {:ok, %{oneof_field: {:oneof_null_value, :NULL_VALUE}}} =
               JSON.from_term(%{"oneofNullValue" => nil}, schema, @p3)
    end

    test "encoding NullValue emits JSON null (singular, emit_defaults)", %{schema: schema} do
      {:ok, json} =
        JSON.to_term(%{optional_null_value: :NULL_VALUE}, schema, @p3, emit_defaults: true)

      assert %{"optionalNullValue" => nil} = json
    end

    test "encoding absent NullValue emits JSON null with emit_defaults", %{schema: schema} do
      {:ok, json} = JSON.to_term(%{}, schema, @p3, emit_defaults: true)

      assert %{"optionalNullValue" => nil} = json
    end

    test "encoding NullValue emits JSON null (oneof member)", %{schema: schema} do
      {:ok, json} =
        JSON.to_term(%{oneof_field: {:oneof_null_value, :NULL_VALUE}}, schema, @p3)

      assert %{"oneofNullValue" => nil} = json
    end

    test "encoding NullValue with enums_as_ints still emits null", %{schema: schema} do
      {:ok, json} =
        JSON.to_term(%{oneof_field: {:oneof_null_value, :NULL_VALUE}}, schema, @p3,
          enums_as_ints: true
        )

      assert %{"oneofNullValue" => nil} = json
    end

    # Coverage for the repeated-NullValue / map-NullValue behaviour that
    # "falls out" of unifying nil handling through `@null_decoded`. The
    # conformance test schema has no such fields, so we spin a tiny one.
    @nv_schema %{
      file: [
        %{
          name: "google/protobuf/struct.proto",
          package: :"google.protobuf",
          syntax: :proto3,
          enum_type: [
            %{name: :NullValue, value: [%{name: :NULL_VALUE, number: 0}]}
          ]
        },
        %{
          name: "nv.proto",
          package: :nv,
          syntax: :proto3,
          dependency: ["google/protobuf/struct.proto"],
          message_type: [
            %{
              name: :M,
              field: [
                %{
                  name: :nulls,
                  number: 1,
                  type: :TYPE_ENUM,
                  label: :LABEL_REPEATED,
                  type_name: :"google.protobuf.NullValue"
                },
                %{
                  name: :null_map,
                  number: 2,
                  type: :TYPE_MESSAGE,
                  label: :LABEL_REPEATED,
                  type_name: :"nv.M.NullMapEntry"
                }
              ],
              nested_type: [
                %{
                  name: :NullMapEntry,
                  options: %{map_entry: true},
                  field: [
                    %{name: :key, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                    %{
                      name: :value,
                      number: 2,
                      type: :TYPE_ENUM,
                      label: :LABEL_OPTIONAL,
                      type_name: :"google.protobuf.NullValue"
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
    }

    test "repeated NullValue accepts null entries" do
      nv = PB.compile(@nv_schema)

      assert {:ok, %{nulls: [:NULL_VALUE, :NULL_VALUE, :NULL_VALUE]}} =
               JSON.from_term(%{"nulls" => [nil, nil, nil]}, nv, :"nv.M")
    end

    test "map<string, NullValue> accepts null entry values" do
      nv = PB.compile(@nv_schema)

      assert {:ok, %{null_map: %{"a" => :NULL_VALUE, "b" => :NULL_VALUE}}} =
               JSON.from_term(%{"nullMap" => %{"a" => nil, "b" => nil}}, nv, :"nv.M")
    end

    test "null still rejected inside arrays of non-nullable types", %{schema: schema} do
      assert {:error, %PB.DecodeError{kind: :malformed_json}} =
               JSON.from_term(%{"repeatedInt32" => [1, nil, 3]}, schema, @p3)
    end
  end

  describe "Value" do
    setup do
      %{schema: PB.TestSupport.TestSchema.schema()}
    end

    @value :"google.protobuf.Value"

    test "decodes JSON null to null_value", %{schema: schema} do
      assert {:ok, %{kind: {:null_value, :NULL_VALUE}}} = JSON.from_term(nil, schema, @value)
    end

    test "decodes JSON booleans", %{schema: schema} do
      assert {:ok, %{kind: {:bool_value, true}}} = JSON.from_term(true, schema, @value)
      assert {:ok, %{kind: {:bool_value, false}}} = JSON.from_term(false, schema, @value)
    end

    test "decodes JSON numbers", %{schema: schema} do
      assert {:ok, %{kind: {:number_value, 42}}} = JSON.from_term(42, schema, @value)
      assert {:ok, %{kind: {:number_value, 1.5}}} = JSON.from_term(1.5, schema, @value)
    end

    test "decodes JSON strings", %{schema: schema} do
      assert {:ok, %{kind: {:string_value, "hello"}}} = JSON.from_term("hello", schema, @value)
    end

    test "decodes JSON arrays to list_value", %{schema: schema} do
      assert {:ok,
              %{
                kind:
                  {:list_value,
                   %{
                     values: [
                       %{kind: {:number_value, 1}},
                       %{kind: {:string_value, "x"}},
                       %{kind: {:null_value, :NULL_VALUE}}
                     ]
                   }}
              }} = JSON.from_term([1, "x", nil], schema, @value)
    end

    test "decodes JSON objects to struct_value", %{schema: schema} do
      assert {:ok,
              %{
                kind:
                  {:struct_value,
                   %{
                     fields: %{
                       "a" => %{kind: {:number_value, 1}},
                       "b" => %{kind: {:bool_value, true}}
                     }
                   }}
              }} = JSON.from_term(%{"a" => 1, "b" => true}, schema, @value)
    end

    test "encode null_value -> JSON null", %{schema: schema} do
      assert {:ok, nil} =
               JSON.to_term(%{kind: {:null_value, :NULL_VALUE}}, schema, @value)
    end

    test "encode bool/string/number members", %{schema: schema} do
      assert {:ok, true} = JSON.to_term(%{kind: {:bool_value, true}}, schema, @value)
      assert {:ok, "hi"} = JSON.to_term(%{kind: {:string_value, "hi"}}, schema, @value)
      assert {:ok, 3.14} = JSON.to_term(%{kind: {:number_value, 3.14}}, schema, @value)
    end

    test "encode rejects NaN / Infinity in number_value", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.to_term(%{kind: {:number_value, :nan}}, schema, @value)

      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.to_term(%{kind: {:number_value, :infinity}}, schema, @value)

      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.to_term(%{kind: {:number_value, :negative_infinity}}, schema, @value)
    end

    test "encode empty Value -> JSON null", %{schema: schema} do
      assert {:ok, nil} = JSON.to_term(%{}, schema, @value)
      assert {:ok, nil} = JSON.to_term(%{kind: nil}, schema, @value)
    end

    test "nested struct_value and list_value round-trip", %{schema: schema} do
      json = %{"k" => [1, %{"inner" => nil}]}
      {:ok, decoded} = JSON.from_term(json, schema, @value)
      assert {:ok, ^json} = JSON.to_term(decoded, schema, @value)
    end

    test "Value nested on host message round-trips", %{schema: schema} do
      fqn = :"protobuf_test_messages.proto3.TestAllTypesProto3"

      assert {:ok, %{"optionalValue" => 7}} =
               JSON.to_term(
                 %{optional_value: %{kind: {:number_value, 7}}},
                 schema,
                 fqn
               )

      assert {:ok, %{optional_value: %{kind: {:number_value, 7}}}} =
               JSON.from_term(%{"optionalValue" => 7}, schema, fqn)
    end

    test "repeated Value field decodes JSON nulls to null_value", %{schema: schema} do
      fqn = :"protobuf_test_messages.proto3.TestAllTypesProto3"

      assert {:ok,
              %{
                repeated_value: [
                  %{kind: {:number_value, 1}},
                  %{kind: {:null_value, :NULL_VALUE}},
                  %{kind: {:string_value, "x"}}
                ]
              }} = JSON.from_term(%{"repeatedValue" => [1, nil, "x"]}, schema, fqn)
    end

    test "singular Value field with JSON null decodes to null_value", %{schema: schema} do
      fqn = :"protobuf_test_messages.proto3.TestAllTypesProto3"

      assert {:ok, %{optional_value: %{kind: {:null_value, :NULL_VALUE}}}} =
               JSON.from_term(%{"optionalValue" => nil}, schema, fqn)
    end

    test "repeated Value field with field-level null leaves field unset", %{schema: schema} do
      fqn = :"protobuf_test_messages.proto3.TestAllTypesProto3"
      assert {:ok, decoded} = JSON.from_term(%{"repeatedValue" => nil}, schema, fqn)
      refute Map.has_key?(decoded, :repeated_value)
    end

    test "encode rejects an unknown null_value enum payload", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_enum_value, value: :BAD}} =
               JSON.to_term(%{kind: {:null_value, :BAD}}, schema, @value)
    end

    test "round-trip through PB binary preserves Value kind shape", %{schema: schema} do
      # `number_value` is TYPE_DOUBLE, so a JSON integer widens to a float
      # through the wire round-trip. Use float input for symmetric comparison.
      input = [1.5, "x", nil, %{"k" => true}]
      {:ok, decoded} = JSON.from_term(input, schema, @value)
      assert {:ok, bin} = PB.encode(decoded, schema, @value)
      assert {:ok, ^decoded} = PB.decode(bin, schema, @value)
      assert {:ok, ^input} = JSON.to_term(decoded, schema, @value)
    end
  end

  describe "Struct" do
    setup do
      %{schema: PB.TestSupport.TestSchema.schema()}
    end

    @struct :"google.protobuf.Struct"

    test "empty struct round-trips", %{schema: schema} do
      assert {:ok, %{}} = JSON.to_term(%{}, schema, @struct)
      assert {:ok, %{fields: %{}}} = JSON.from_term(%{}, schema, @struct)
    end

    test "encodes Struct as a JSON object of Value members", %{schema: schema} do
      data = %{
        fields: %{
          "name" => %{kind: {:string_value, "alice"}},
          "age" => %{kind: {:number_value, 30}}
        }
      }

      assert {:ok, %{"name" => "alice", "age" => 30}} = JSON.to_term(data, schema, @struct)
    end

    test "decodes a JSON object into Struct fields", %{schema: schema} do
      assert {:ok,
              %{
                fields: %{
                  "name" => %{kind: {:string_value, "alice"}},
                  "age" => %{kind: {:number_value, 30}}
                }
              }} = JSON.from_term(%{"name" => "alice", "age" => 30}, schema, @struct)
    end

    test "Struct with empty list value", %{schema: schema} do
      data = %{fields: %{"items" => %{kind: {:list_value, %{values: []}}}}}
      assert {:ok, %{"items" => []}} = JSON.to_term(data, schema, @struct)
      assert {:ok, ^data} = JSON.from_term(%{"items" => []}, schema, @struct)
    end

    test "decode rejects non-object", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} = JSON.from_term([], schema, @struct)

      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term("nope", schema, @struct)
    end

    test "encode rejects non-string keys", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.to_term(
                 %{fields: %{42 => %{kind: {:string_value, "x"}}}},
                 schema,
                 @struct
               )
    end

    test "encode rejects a struct in place of the fields map", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.to_term(%{fields: %PB.ValueError{}}, schema, @struct)
    end

    test "Struct nested on host message round-trips", %{schema: schema} do
      fqn = :"protobuf_test_messages.proto3.TestAllTypesProto3"
      json = %{"optionalStruct" => %{"k" => "v"}}
      {:ok, decoded} = JSON.from_term(json, schema, fqn)

      assert %{
               optional_struct: %{
                 fields: %{"k" => %{kind: {:string_value, "v"}}}
               }
             } = decoded

      assert {:ok, ^json} = JSON.to_term(decoded, schema, fqn)
    end
  end

  describe "ListValue" do
    setup do
      %{schema: PB.TestSupport.TestSchema.schema()}
    end

    @list_value :"google.protobuf.ListValue"

    test "empty list round-trips", %{schema: schema} do
      assert {:ok, []} = JSON.to_term(%{}, schema, @list_value)
      assert {:ok, %{values: []}} = JSON.from_term([], schema, @list_value)
    end

    test "encodes mixed scalar entries", %{schema: schema} do
      data = %{
        values: [
          %{kind: {:number_value, 1}},
          %{kind: {:string_value, "x"}},
          %{kind: {:null_value, :NULL_VALUE}},
          %{kind: {:bool_value, true}}
        ]
      }

      assert {:ok, [1, "x", nil, true]} = JSON.to_term(data, schema, @list_value)
    end

    test "decode rejects non-array", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term(%{"a" => 1}, schema, @list_value)

      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term("nope", schema, @list_value)
    end

    test "repeated ListValue field round-trips", %{schema: schema} do
      fqn = :"protobuf_test_messages.proto3.TestAllTypesProto3"
      json = %{"repeatedListValue" => [[1, "a", nil], []]}
      {:ok, decoded} = JSON.from_term(json, schema, fqn)
      assert {:ok, ^json} = JSON.to_term(decoded, schema, fqn)
    end
  end

  describe "Any" do
    setup do
      %{schema: PB.TestSupport.TestSchema.schema()}
    end

    @any :"google.protobuf.Any"
    @inner_fqn :"protobuf_test_messages.proto3.TestAllTypesProto3"

    defp any_for(schema, fqn, data) do
      {:ok, bytes_iodata} = PB.encode(data, schema, fqn)

      %{
        type_url: "type.googleapis.com/" <> Atom.to_string(fqn),
        value: IO.iodata_to_binary(bytes_iodata)
      }
    end

    test "empty {} round-trips to Any with empty type_url and value", %{schema: schema} do
      assert {:ok, %{type_url: "", value: ""}} = JSON.from_term(%{}, schema, @any)
      assert {:ok, %{}} = JSON.to_term(%{type_url: "", value: ""}, schema, @any)
      assert {:ok, %{}} = JSON.to_term(%{}, schema, @any)
    end

    test "non-WKT inner: flat merge with @type", %{schema: schema} do
      any_data = any_for(schema, @inner_fqn, %{optional_int32: 42})

      assert {:ok, %{"@type" => url, "optionalInt32" => 42}} =
               JSON.to_term(any_data, schema, @any)

      assert url ==
               "type.googleapis.com/protobuf_test_messages.proto3.TestAllTypesProto3"

      json = %{"@type" => url, "optionalInt32" => 42}
      assert {:ok, ^any_data} = JSON.from_term(json, schema, @any)
    end

    test "WKT inner (Duration): value-wrapped", %{schema: schema} do
      any_data = any_for(schema, :"google.protobuf.Duration", %{seconds: 5, nanos: 0})

      assert {:ok, %{"@type" => "type.googleapis.com/google.protobuf.Duration", "value" => "5s"}} =
               JSON.to_term(any_data, schema, @any)

      json = %{"@type" => "type.googleapis.com/google.protobuf.Duration", "value" => "5s"}
      assert {:ok, ^any_data} = JSON.from_term(json, schema, @any)
    end

    test "WKT inner (Timestamp)", %{schema: schema} do
      any_data = any_for(schema, :"google.protobuf.Timestamp", %{seconds: 0, nanos: 0})

      json = %{
        "@type" => "type.googleapis.com/google.protobuf.Timestamp",
        "value" => "1970-01-01T00:00:00Z"
      }

      assert {:ok, ^json} = JSON.to_term(any_data, schema, @any)
      assert {:ok, ^any_data} = JSON.from_term(json, schema, @any)
    end

    test "WKT inner (FieldMask)", %{schema: schema} do
      any_data = any_for(schema, :"google.protobuf.FieldMask", %{paths: ["foo_bar"]})

      json = %{
        "@type" => "type.googleapis.com/google.protobuf.FieldMask",
        "value" => "fooBar"
      }

      assert {:ok, ^json} = JSON.to_term(any_data, schema, @any)
      assert {:ok, ^any_data} = JSON.from_term(json, schema, @any)
    end

    test "WKT inner (Int32Value wrapper)", %{schema: schema} do
      any_data = any_for(schema, :"google.protobuf.Int32Value", %{value: 7})

      json = %{
        "@type" => "type.googleapis.com/google.protobuf.Int32Value",
        "value" => 7
      }

      assert {:ok, ^json} = JSON.to_term(any_data, schema, @any)
      assert {:ok, ^any_data} = JSON.from_term(json, schema, @any)
    end

    test "WKT inner (Struct): value-wrapped despite object form", %{schema: schema} do
      any_data =
        any_for(schema, :"google.protobuf.Struct", %{
          fields: %{"k" => %{kind: {:string_value, "v"}}}
        })

      json = %{
        "@type" => "type.googleapis.com/google.protobuf.Struct",
        "value" => %{"k" => "v"}
      }

      assert {:ok, ^json} = JSON.to_term(any_data, schema, @any)
      assert {:ok, ^any_data} = JSON.from_term(json, schema, @any)
    end

    test "WKT inner (Value with integer)", %{schema: schema} do
      any_data = any_for(schema, :"google.protobuf.Value", %{kind: {:number_value, 42.0}})

      json = %{
        "@type" => "type.googleapis.com/google.protobuf.Value",
        "value" => 42.0
      }

      assert {:ok, ^json} = JSON.to_term(any_data, schema, @any)
      assert {:ok, ^any_data} = JSON.from_term(json, schema, @any)
    end

    test "WKT inner (Value wrapping a JSON object)", %{schema: schema} do
      struct = %{fields: %{"k" => %{kind: {:string_value, "v"}}}}
      any_data = any_for(schema, :"google.protobuf.Value", %{kind: {:struct_value, struct}})

      json = %{
        "@type" => "type.googleapis.com/google.protobuf.Value",
        "value" => %{"k" => "v"}
      }

      assert {:ok, ^json} = JSON.to_term(any_data, schema, @any)
      assert {:ok, ^any_data} = JSON.from_term(json, schema, @any)
    end

    test "@type may appear at any position in the JSON object", %{schema: schema} do
      url = "type.googleapis.com/protobuf_test_messages.proto3.TestAllTypesProto3"
      json = %{"optionalInt32" => 1, "@type" => url, "optionalString" => "x"}

      assert {:ok, %{type_url: ^url, value: bytes}} = JSON.from_term(json, schema, @any)
      assert is_binary(bytes) and byte_size(bytes) > 0
    end

    test "AnyNested: Any wrapping Any", %{schema: schema} do
      inner = any_for(schema, :"google.protobuf.Duration", %{seconds: 1, nanos: 0})
      outer = any_for(schema, @any, inner)

      json = %{
        "@type" => "type.googleapis.com/google.protobuf.Any",
        "value" => %{
          "@type" => "type.googleapis.com/google.protobuf.Duration",
          "value" => "1s"
        }
      }

      assert {:ok, ^json} = JSON.to_term(outer, schema, @any)
      assert {:ok, ^outer} = JSON.from_term(json, schema, @any)
    end

    test "decode accepts any host in the type_url (canonical ProtoJSON)", %{schema: schema} do
      # Only the final path segment names the type; the host is arbitrary and
      # may include extra path segments. The @type round-trips verbatim.
      for url <- [
            "example.com/google.protobuf.Duration",
            "foo/bar/google.protobuf.Duration",
            "/google.protobuf.Duration"
          ] do
        json = %{"@type" => url, "value" => "5s"}
        assert {:ok, %{type_url: ^url, value: bytes}} = JSON.from_term(json, schema, @any)
        assert is_binary(bytes) and byte_size(bytes) > 0
      end
    end

    test "decode rejects a type_url with no '/' or empty final segment", %{schema: schema} do
      for url <- ["google.protobuf.Duration", "type.googleapis.com/"] do
        json = %{"@type" => url, "value" => "5s"}

        assert {:error, %PB.ValueError{kind: :invalid_value}} =
                 JSON.from_term(json, schema, @any)
      end
    end

    test "decode rejects missing @type when object is non-empty", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term(%{"foo" => 1}, schema, @any)
    end

    test "decode rejects unknown FQN", %{schema: schema} do
      json = %{"@type" => "type.googleapis.com/not.a.real.Type", "value" => "x"}

      assert {:error, %PB.SchemaError{kind: :unknown_message}} =
               JSON.from_term(json, schema, @any)
    end

    test "decode rejects non-object input", %{schema: schema} do
      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term("nope", schema, @any)
    end

    test "WKT inner without 'value' key is rejected on decode", %{schema: schema} do
      json = %{"@type" => "type.googleapis.com/google.protobuf.Duration"}

      assert {:error, %PB.ValueError{kind: :invalid_value}} =
               JSON.from_term(json, schema, @any)
    end

    test "Any nested on host message round-trips", %{schema: schema} do
      url = "type.googleapis.com/google.protobuf.Duration"
      # Duration always re-emits at 3/6/9-digit precision, so input must be
      # already-canonical to round-trip byte-for-byte.
      json = %{"optionalAny" => %{"@type" => url, "value" => "3.500s"}}
      {:ok, decoded} = JSON.from_term(json, schema, @inner_fqn)
      assert {:ok, ^json} = JSON.to_term(decoded, schema, @inner_fqn)
    end

    test "wrapped-WKT Any rejects sibling keys beyond @type and value", %{schema: schema} do
      json = %{
        "@type" => "type.googleapis.com/google.protobuf.Duration",
        "value" => "5s",
        "extra" => 1
      }

      assert {:error, %PB.ValueError{kind: :unknown_field, path: ["extra"]}} =
               JSON.from_term(json, schema, @any)
    end

    test "wrapped-WKT Any allows sibling keys with ignore_unknown: true", %{schema: schema} do
      json = %{
        "@type" => "type.googleapis.com/google.protobuf.Duration",
        "value" => "5s",
        "extra" => 1
      }

      expected = any_for(schema, :"google.protobuf.Duration", %{seconds: 5, nanos: 0})
      assert {:ok, ^expected} = JSON.from_term(json, schema, @any, ignore_unknown: true)
    end

    test "WKT inner (BoolValue wrapper)", %{schema: schema} do
      any_data = any_for(schema, :"google.protobuf.BoolValue", %{value: true})

      json = %{
        "@type" => "type.googleapis.com/google.protobuf.BoolValue",
        "value" => true
      }

      assert {:ok, ^json} = JSON.to_term(any_data, schema, @any)
      assert {:ok, ^any_data} = JSON.from_term(json, schema, @any)
    end

    test "WKT inner (StringValue wrapper)", %{schema: schema} do
      any_data = any_for(schema, :"google.protobuf.StringValue", %{value: "hello"})

      json = %{
        "@type" => "type.googleapis.com/google.protobuf.StringValue",
        "value" => "hello"
      }

      assert {:ok, ^json} = JSON.to_term(any_data, schema, @any)
      assert {:ok, ^any_data} = JSON.from_term(json, schema, @any)
    end
  end

  defp nested_recursive_message(depth) do
    Enum.reduce(1..depth, %{}, fn _, acc -> %{"recursiveMessage" => acc} end)
  end

  defp nested_array(depth) do
    Enum.reduce(1..depth, nil, fn _, acc -> [acc] end)
  end

  defp nested_array_json(depth) do
    String.duplicate("[", depth) <> "null" <> String.duplicate("]", depth)
  end

  defp nested_object(depth) do
    Enum.reduce(1..depth, nil, fn _, acc -> %{"value" => acc} end)
  end

  describe "Any packing a projected type" do
    @nested :"protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage"

    setup do
      descriptor_set = PB.decode_descriptor_set!(File.read!("test/fixtures/schema/test.binpb"))

      schema =
        PB.compile(descriptor_set,
          projections: [{@nested, struct: Nested} | PB.WellKnownTypes.projections([:time])]
        )

      %{schema: schema}
    end

    test "decodes and encodes a struct-projected message", %{schema: schema} do
      {:ok, value} = PB.encode(%Nested{a: 5}, schema, @nested)
      any = %{type_url: "type.googleapis.com/#{@nested}", value: value}
      json = %{"@type" => "type.googleapis.com/#{@nested}", "a" => 5}

      assert JSON.from_term(json, schema, :"google.protobuf.Any") == {:ok, any}
      assert JSON.to_term(any, schema, :"google.protobuf.Any") == {:ok, json}
    end

    test "decodes and encodes an adapted well-known type", %{schema: schema} do
      {:ok, value} = PB.encode({:duration, 1_500_000_000}, schema, :"google.protobuf.Duration")
      any = %{type_url: "type.googleapis.com/google.protobuf.Duration", value: value}
      json = %{"@type" => "type.googleapis.com/google.protobuf.Duration", "value" => "1.500s"}

      assert JSON.from_term(json, schema, :"google.protobuf.Any") == {:ok, any}
      assert JSON.to_term(any, schema, :"google.protobuf.Any") == {:ok, json}
    end
  end
end

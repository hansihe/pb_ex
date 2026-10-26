# Compares PB's runtime (data-driven) encode/decode path against its codegen
# path (per-message generated encoders/decoders). Both are PB; this is not a
# cross-library comparison. See pb_vs_protobuf.exs for PB vs the `protobuf`
# library.
#
# Run from the bench project:
#
#     cd bench && mix run codegen_vs_runtime.exs
#
# Optional timing knobs:
#
#     BENCH_WARMUP=2 BENCH_TIME=5 mix run codegen_vs_runtime.exs

for file <- [
      "../test/support/pb/codegen/typespec.ex",
      "../test/support/pb/codegen/runtime.ex",
      "../test/support/pb/codegen/encoder.ex",
      "../test/support/pb/codegen/decoder.ex",
      "../test/support/pb/codegen.ex"
    ] do
  Code.require_file(file, __DIR__)
end

defmodule PB.Bench.CodegenVsRuntime do
  @moduledoc false

  @generated_module Module.concat(__MODULE__, Generated)

  @person :"bench.Person"
  @scalars :"bench.Scalars"
  @packed :"bench.Packed"

  @roots [
    {@person, as: :person},
    {@scalars, as: :scalars},
    {@packed, as: :packed}
  ]

  def run do
    schema =
      descriptor_set()
      |> PB.compile()
      |> PB.Schema.Transform.slice(roots: @roots)

    compile_generated!(schema)

    inputs = build_inputs(schema)

    Benchee.run(jobs(),
      inputs: inputs,
      warmup: duration_env("BENCH_WARMUP", 1),
      time: duration_env("BENCH_TIME", 3)
    )
  end

  defp compile_generated!(schema) do
    ast = PB.Codegen.module(@generated_module, schema, emit: [:encoder, :decoder])

    case Code.compile_quoted(ast) do
      [{@generated_module, _binary}] ->
        :ok

      compiled ->
        raise "expected #{@generated_module} to be compiled, got: #{inspect(compiled)}"
    end
  end

  defp build_inputs(schema) do
    scenarios()
    |> Map.new(fn scenario ->
      runtime_binary = scenario.message |> PB.encode!(schema, scenario.root) |> to_binary()
      codegen_binary = scenario.message |> scenario.codegen_encode!.() |> to_binary()

      unless runtime_binary == codegen_binary do
        raise "runtime and codegen encode outputs differ for #{scenario.name}"
      end

      runtime_decoded = PB.decode!(runtime_binary, schema, scenario.root, defaults: true)
      codegen_decoded = scenario.codegen_decode!.(runtime_binary)

      unless runtime_decoded == codegen_decoded do
        raise "runtime defaults decode and codegen decode outputs differ for #{scenario.name}"
      end

      {scenario.name, Map.merge(scenario, %{schema: schema, binary: runtime_binary})}
    end)
  end

  defp jobs do
    %{
      "runtime encode (iodata)" => fn input ->
        PB.encode!(input.message, input.schema, input.root)
      end,
      "codegen encode (iodata)" => fn input ->
        input.codegen_encode!.(input.message)
      end,
      "runtime encode (binary)" => fn input ->
        input.message
        |> PB.encode!(input.schema, input.root)
        |> to_binary()
      end,
      "codegen encode (binary)" => fn input ->
        input.message
        |> input.codegen_encode!.()
        |> to_binary()
      end,
      "runtime decode (no defaults)" => fn input ->
        PB.decode!(input.binary, input.schema, input.root)
      end,
      "runtime decode (defaults)" => fn input ->
        PB.decode!(input.binary, input.schema, input.root, defaults: true)
      end,
      "codegen decode" => fn input ->
        input.codegen_decode!.(input.binary)
      end
    }
  end

  defp scenarios do
    [
      %{
        name: "person/full nested repeated map",
        root: @person,
        message: person_full(),
        codegen_encode!: &@generated_module.encode_person!/1,
        codegen_decode!: &@generated_module.decode_person!/1
      },
      %{
        name: "person/sparse defaults",
        root: @person,
        message: %{id: 7},
        codegen_encode!: &@generated_module.encode_person!/1,
        codegen_decode!: &@generated_module.decode_person!/1
      },
      %{
        name: "scalars/all scalar wire types",
        root: @scalars,
        message: scalars(),
        codegen_encode!: &@generated_module.encode_scalars!/1,
        codegen_decode!: &@generated_module.decode_scalars!/1
      },
      %{
        name: "packed/repeated numerics",
        root: @packed,
        message: packed(),
        codegen_encode!: &@generated_module.encode_packed!/1,
        codegen_decode!: &@generated_module.decode_packed!/1
      }
    ]
  end

  defp person_full do
    %{
      name: "Alice Example",
      id: 42,
      phones:
        for idx <- 1..8 do
          %{number: "555-01#{String.pad_leading(Integer.to_string(idx), 2, "0")}"}
        end,
      role: :ADMIN,
      scores: Enum.to_list(1..64),
      companion: {:pet, %{name: "Rex"}},
      tags:
        1..24
        |> Map.new(fn idx -> {"tag-#{idx}", idx * 10} end)
    }
  end

  defp scalars do
    %{
      f_double: 3.141592653589793,
      f_float: 1.5,
      f_int64: -9_999_999_999,
      f_uint64: 18_446_744_073_709_551_615,
      f_int32: -42,
      f_fixed64: 123_456_789,
      f_fixed32: 42,
      f_bool: true,
      f_string: String.duplicate("text", 8),
      f_bytes: <<0, 1, 2, 255>> <> String.duplicate("payload", 4),
      f_uint32: 4_294_967_295,
      f_sfixed32: -42,
      f_sfixed64: -999_999,
      f_sint32: -100,
      f_sint64: -100_000_000_000
    }
  end

  defp packed do
    %{
      ints: Enum.to_list(-128..127),
      sint64s: Enum.map(1..128, &(&1 * -123_456)),
      doubles: Enum.map(1..96, &(&1 / 3)),
      bools: Enum.map(1..192, &(rem(&1, 2) == 0))
    }
  end

  defp to_binary(iodata), do: IO.iodata_to_binary(iodata)

  defp duration_env(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Float.parse(value) do
          {duration, ""} when duration >= 0 ->
            duration

          _ ->
            raise "#{name} must be a non-negative number of seconds, got: #{inspect(value)}"
        end
    end
  end

  defp descriptor_set do
    %{
      file: [
        %{
          name: "bench.proto",
          package: :bench,
          syntax: :proto3,
          message_type: [
            person_descriptor(),
            phone_number_descriptor(),
            pet_descriptor(),
            fish_descriptor(),
            scalars_descriptor(),
            packed_descriptor()
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
  end

  defp person_descriptor do
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
          type_name: :"bench.PhoneNumber"
        },
        %{
          name: :role,
          number: 5,
          type: :TYPE_ENUM,
          label: :LABEL_OPTIONAL,
          type_name: :"bench.Role"
        },
        %{name: :scores, number: 6, type: :TYPE_INT32, label: :LABEL_REPEATED},
        %{
          name: :pet,
          number: 7,
          type: :TYPE_MESSAGE,
          label: :LABEL_OPTIONAL,
          type_name: :"bench.Pet",
          oneof_index: 0
        },
        %{
          name: :fish,
          number: 8,
          type: :TYPE_MESSAGE,
          label: :LABEL_OPTIONAL,
          type_name: :"bench.Fish",
          oneof_index: 0
        },
        %{
          name: :tags,
          number: 9,
          type: :TYPE_MESSAGE,
          label: :LABEL_REPEATED,
          type_name: :"bench.Person.TagsEntry"
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
    }
  end

  defp phone_number_descriptor do
    %{
      name: :PhoneNumber,
      field: [
        %{name: :number, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
      ]
    }
  end

  defp pet_descriptor do
    %{
      name: :Pet,
      field: [
        %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
      ]
    }
  end

  defp fish_descriptor do
    %{
      name: :Fish,
      field: [
        %{name: :species, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
      ]
    }
  end

  defp scalars_descriptor do
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
  end

  defp packed_descriptor do
    %{
      name: :Packed,
      field: [
        %{name: :ints, number: 1, type: :TYPE_INT32, label: :LABEL_REPEATED},
        %{name: :sint64s, number: 2, type: :TYPE_SINT64, label: :LABEL_REPEATED},
        %{name: :doubles, number: 3, type: :TYPE_DOUBLE, label: :LABEL_REPEATED},
        %{name: :bools, number: 4, type: :TYPE_BOOL, label: :LABEL_REPEATED}
      ]
    }
  end
end

PB.Bench.CodegenVsRuntime.run()

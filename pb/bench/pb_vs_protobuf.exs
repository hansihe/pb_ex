# Benchmarks PB's compile-time schema path (`use PB.Schema`) against the
# Elixir `protobuf` library's generated modules, on identical schemas and
# payloads.
#
# Run with:
#
#     mix run bench/pb_vs_protobuf.exs
#
# Optional timing knobs:
#
#     BENCH_WARMUP=2 BENCH_TIME=5 mix run bench/pb_vs_protobuf.exs
#
# Run it from the bench project:
#
#     cd bench && mix run pb_vs_protobuf.exs
#
# Prerequisites (checked into bench/): the shared schema is
# proto/pb_bench.proto, compiled to:
#
#   * proto/pb_bench.binpb   -> descriptor set consumed by PB
#   * lib/pb_bench.pb.ex      -> `protobuf` modules (protoc-gen-elixir), compiled
#                               into this project
#
# Regenerate both (and refresh the docs results block) with bench/run.sh.

defmodule PB.Bench.Schema do
  @moduledoc false
  # PB's compile-time path: the descriptor set is read and compiled into this
  # module at Elixir compile time, the direct analogue of protoc-gen-elixir.
  use PB.Schema, descriptor: "proto/pb_bench.binpb"
end

defmodule PB.Bench.PBvsProtobuf do
  @moduledoc false

  alias PB.Bench.Schema

  @person :"bench.Person"
  @scalars :"bench.Scalars"
  @packed :"bench.Packed"

  def run do
    scenarios = scenarios()

    # Correctness gate: prove both libraries agree on the wire before timing
    # anything. Map fields (Person.tags) may serialize entries in different
    # orders, so we check *semantic* equality by cross-decoding rather than
    # comparing raw bytes.
    Enum.each(scenarios, &verify!/1)

    inputs =
      Map.new(scenarios, fn s ->
        {s.name,
         %{
           pb_message: s.pb_message,
           pb_name: s.pb_name,
           pf_struct: s.pf_struct,
           pf_mod: s.pf_mod,
           # Canonical bytes both libraries decode in the decode suite.
           binary: PB.encode!(s.pb_message, Schema, s.pb_name)
         }}
      end)

    IO.puts("\n=== ENCODE (Elixir term -> wire bytes) ===")
    Benchee.run(encode_jobs(), benchee_opts(inputs))

    IO.puts("\n=== DECODE (wire bytes -> Elixir term) ===")
    Benchee.run(decode_jobs(), benchee_opts(inputs))
  end

  defp benchee_opts(inputs) do
    [
      inputs: inputs,
      warmup: duration_env("BENCH_WARMUP", 1),
      time: duration_env("BENCH_TIME", 3),
      memory_time: duration_env("BENCH_MEMORY", 1),
      # Quiet the per-job progress lines so captured output stays clean.
      print: [benchmarking: false, fast_warning: false]
    ]
  end

  defp encode_jobs do
    %{
      # PB's native output is iodata (skips a final copy when writing to a
      # socket); the binary job adds IO.iodata_to_binary to match protobuf.
      "PB encode (iodata)" => fn i ->
        PB.encode_iodata!(i.pb_message, Schema, i.pb_name)
      end,
      "PB encode (binary)" => fn i ->
        PB.encode!(i.pb_message, Schema, i.pb_name)
      end,
      "protobuf encode (binary)" => fn i ->
        i.pf_mod.encode(i.pf_struct)
      end
    }
  end

  defp decode_jobs do
    %{
      "PB decode (no defaults)" => fn i ->
        PB.decode!(i.binary, Schema, i.pb_name)
      end,
      "PB decode (defaults)" => fn i ->
        PB.decode!(i.binary, Schema, i.pb_name, defaults: true)
      end,
      "protobuf decode" => fn i ->
        i.pf_mod.decode(i.binary)
      end
    }
  end

  defp verify!(s) do
    pb_bin = PB.encode!(s.pb_message, Schema, s.pb_name)
    pf_bin = IO.iodata_to_binary(s.pf_mod.encode(s.pf_struct))

    # Gate 1: PB reads both encoders' bytes to the same value.
    pb_of_pb = PB.decode!(pb_bin, Schema, s.pb_name, defaults: true)
    pb_of_pf = PB.decode!(pf_bin, Schema, s.pb_name, defaults: true)

    unless pb_of_pb == pb_of_pf do
      raise """
      [#{s.name}] PB decodes the two encoders' bytes differently:
        from PB bytes:       #{inspect(pb_of_pb)}
        from protobuf bytes: #{inspect(pb_of_pf)}
      """
    end

    # Gate 2: protobuf reads both encoders' bytes to the same value.
    pf_of_pb = s.pf_mod.decode(pb_bin)
    pf_of_pf = s.pf_mod.decode(pf_bin)

    unless pf_of_pb == pf_of_pf do
      raise """
      [#{s.name}] protobuf decodes the two encoders' bytes differently:
        from PB bytes:       #{inspect(pf_of_pb)}
        from protobuf bytes: #{inspect(pf_of_pf)}
      """
    end

    if pb_bin == pf_bin do
      IO.puts("  ok  #{s.name} (byte-identical, #{byte_size(pb_bin)} B)")
    else
      IO.puts(
        "  ok  #{s.name} (semantically equal; byte order differs in map field, " <>
          "#{byte_size(pb_bin)} vs #{byte_size(pf_bin)} B)"
      )
    end
  end

  # --- Scenarios: twinned payloads (PB map + protobuf struct) ---------------

  defp scenarios do
    [
      %{
        name: "person/full nested repeated map",
        pb_name: @person,
        pb_message: person_full(),
        pf_mod: Bench.Person,
        pf_struct: to_person(person_full())
      },
      %{
        name: "person/sparse defaults",
        pb_name: @person,
        pb_message: %{id: 7},
        pf_mod: Bench.Person,
        pf_struct: to_person(%{id: 7})
      },
      %{
        name: "scalars/all scalar wire types",
        pb_name: @scalars,
        pb_message: scalars(),
        pf_mod: Bench.Scalars,
        pf_struct: struct(Bench.Scalars, scalars())
      },
      %{
        name: "packed/repeated numerics",
        pb_name: @packed,
        pb_message: packed(),
        pf_mod: Bench.Packed,
        pf_struct: struct(Bench.Packed, packed())
      }
    ]
  end

  # PB uses plain maps; protobuf uses nested structs. Same field names, same
  # oneof shape ({:pet, _}), same enum atoms — only the wrapper differs.
  defp to_person(map) do
    fields =
      map
      |> Map.replace_lazy(:phones, &Enum.map(&1, fn p -> struct(Bench.PhoneNumber, p) end))
      |> Map.replace_lazy(:companion, fn
        {:pet, p} -> {:pet, struct(Bench.Pet, p)}
        {:fish, f} -> {:fish, struct(Bench.Fish, f)}
      end)

    struct(Bench.Person, fields)
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

  defp duration_env(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Float.parse(value) do
          {duration, ""} when duration >= 0 -> duration
          _ -> raise "#{name} must be a non-negative number of seconds, got: #{inspect(value)}"
        end
    end
  end
end

PB.Bench.PBvsProtobuf.run()

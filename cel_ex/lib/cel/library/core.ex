defmodule CEL.Library.Core do
  @moduledoc false

  alias CEL.Function
  alias CEL.Function.Overload
  alias CEL.Runtime.Convert, as: RuntimeConvert
  alias CEL.Runtime.Core, as: RuntimeCore

  @matcher_suffixes %{
    dyn: "dyn",
    bool: "bool",
    int: "int64",
    uint: "uint64",
    double: "double",
    string: "string",
    bytes: "bytes",
    timestamp: "timestamp",
    duration: "duration"
  }

  @conversion_runtimes %{
    bool: {RuntimeConvert, :to_bool},
    bytes: {RuntimeConvert, :to_bytes},
    double: {RuntimeConvert, :to_double},
    int: {RuntimeConvert, :to_int},
    string: {RuntimeConvert, :to_string},
    timestamp: {RuntimeConvert, :to_timestamp},
    duration: {RuntimeConvert, :to_duration},
    uint: {RuntimeConvert, :to_uint}
  }

  @conversion_functions (for {target, sources} <- [
                               bool: [:dyn, :bool, :string],
                               bytes: [:dyn, :bytes, :string],
                               double: [:dyn, :double, :int, :uint, :string],
                               int: [:dyn, :int, :uint, :double, :string, :timestamp],
                               string: [
                                 :dyn,
                                 :string,
                                 :bool,
                                 :int,
                                 :uint,
                                 :double,
                                 :bytes,
                                 :timestamp,
                                 :duration
                               ],
                               timestamp: [:dyn, :timestamp, :int, :string],
                               duration: [:dyn, :duration, :string],
                               uint: [:dyn, :uint, :int, :double, :string]
                             ] do
                           {dynamic_sources, static_sources} =
                             Enum.split_with(sources, &(&1 == :dyn))

                           conversion_overload = fn source ->
                             %Overload{
                               id:
                                 "convert_" <>
                                   Map.fetch!(@matcher_suffixes, source) <>
                                   "_to_" <> Atom.to_string(target),
                               args: [source],
                               result: target,
                               eval: {:mfa, Map.fetch!(@conversion_runtimes, target)}
                             }
                           end

                           %Function{
                             name: Atom.to_string(target),
                             modes: [:global],
                             overloads: Enum.map(static_sources, conversion_overload),
                             dynamic_overloads: Enum.map(dynamic_sources, conversion_overload)
                           }
                         end)

  @size_function %Function{
    name: "size",
    modes: [:global, :receiver],
    dynamic_overloads: [
      %Overload{id: "size_dyn", args: [:dyn], result: :int, eval: {:mfa, {RuntimeCore, :size}}}
    ],
    overloads: [
      %Overload{
        id: "size_string",
        args: [:string],
        result: :int,
        eval: {:mfa, {RuntimeCore, :size}}
      },
      %Overload{
        id: "size_bytes",
        args: [:bytes],
        result: :int,
        eval: {:mfa, {RuntimeCore, :size}}
      },
      %Overload{
        id: "size_list",
        args: [:list],
        result: :int,
        eval: {:mfa, {RuntimeCore, :size}}
      },
      %Overload{id: "size_map", args: [:map], result: :int, eval: {:mfa, {RuntimeCore, :size}}}
    ]
  }

  @functions @conversion_functions ++ [@size_function]

  @spec functions() :: [Function.t()]
  def functions, do: @functions
end

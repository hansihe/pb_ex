defmodule PB.CEL.Library do
  @moduledoc false

  alias PB.CEL.Function
  alias PB.CEL.Library.Core
  alias PB.CEL.Library.Encoders
  alias PB.CEL.Library.Intrinsics
  alias PB.CEL.Library.Math
  alias PB.CEL.Library.Strings
  alias PB.CEL.Library.Time

  @function_families [Intrinsics, Core, Encoders, Strings, Math, Time]

  # CEL call names that aren't ordinary overload-resolved functions — handled
  # by Checker.try_infer_special. dyn/type are folded into :call ops with
  # Runtime.Core MFAs; optMap/optFlatMap emit :special ops with scope binding.
  @special_call_names [
    "bind",
    "dyn",
    "type",
    "optFlatMap",
    "optMap"
  ]

  @spec functions() :: [Function.t()]
  def functions, do: Enum.flat_map(@function_families, & &1.functions())

  @spec supported_call_names() :: MapSet.t(String.t())
  def supported_call_names do
    functions()
    |> Enum.flat_map(&Function.call_names/1)
    |> Kernel.++(@special_call_names)
    |> MapSet.new()
  end
end

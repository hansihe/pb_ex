defmodule PB.CEL.Type do
  @moduledoc """
  CEL types, in the shorthand `PB.CEL` uses wherever it takes or returns a
  type: variable declarations in `PB.CEL.Env.build/1`, overload signatures in
  `PB.CEL.Function.Overload`, and the types of `PB.CEL.Expr` nodes and
  `PB.CEL.Checked.type/2`.

    * `:bool`, `:int`, `:uint`, `:double`, `:string`, `:bytes`
    * `:timestamp` and `:duration` — `google.protobuf.Timestamp` and
      `google.protobuf.Duration`
    * `:null` and `:dyn`
    * `{:list, t}` and `{:map, key, value}`
    * `{:message, "pkg.Message"}` — a protobuf message, by full name
    * `{:wrapper, primitive}` — a wrapper message such as
      `google.protobuf.Int64Value` (`{:wrapper, :int}`)
    * `{:optional, t}` — `optional_type(t)`
    * `{:type, t}` — the type of a type value; `:type` alone is
      `{:type, :dyn}` when declaring
    * `{:abstract, name, params}` — any other parameterised type

  An enum-typed expression has type `:int`, as in CEL.
  """

  alias PB.CEL.Checker.Types, as: CheckerTypes

  @type primitive :: :bool | :int | :uint | :double | :string | :bytes

  @type t ::
          :dyn
          | :null
          | primitive
          | :timestamp
          | :duration
          | {:wrapper, primitive}
          | {:type, t}
          | {:list, t}
          | {:map, t, t}
          | {:message, String.t()}
          | {:optional, t}
          | {:abstract, String.t(), [t]}

  @timestamp {:message, "google.protobuf.Timestamp"}
  @duration {:message, "google.protobuf.Duration"}

  @doc """
  Spells a type as CEL does, for messages to users.

      iex> PB.CEL.Type.format({:map, :string, {:list, :int}})
      "map(string, list(int))"

      iex> PB.CEL.Type.format(:timestamp)
      "google.protobuf.Timestamp"
  """
  @spec format(t) :: String.t()
  def format(type), do: type |> CheckerTypes.from_input() |> CheckerTypes.format()

  # The checker spells timestamp and duration as their messages and may leave
  # an unresolved type variable, which is dyn to a reader.
  @doc false
  @spec from_checker(CheckerTypes.t()) :: t
  def from_checker(@timestamp), do: :timestamp
  def from_checker(@duration), do: :duration
  def from_checker({:var, _id}), do: :dyn
  def from_checker({:type, type}), do: {:type, from_checker(type)}
  def from_checker({:list, elem}), do: {:list, from_checker(elem)}
  def from_checker({:map, key, value}), do: {:map, from_checker(key), from_checker(value)}
  def from_checker({:optional, value}), do: {:optional, from_checker(value)}

  def from_checker({:abstract, name, params}),
    do: {:abstract, name, Enum.map(params, &from_checker/1)}

  def from_checker(type), do: type
end

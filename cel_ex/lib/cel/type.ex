defmodule CEL.Type do
  @moduledoc """
  CEL types, in the shorthand `CEL` uses wherever it takes or returns a
  type: variable declarations in `CEL.Env.build/1`, overload signatures in
  `CEL.Function.Overload`, and the types of `CEL.Expr` nodes and
  `CEL.Checked.type/2`.

    * `:bool`, `:int`, `:uint`, `:double`, `:string`, `:bytes`
    * `:timestamp` and `:duration` — `google.protobuf.Timestamp` and
      `google.protobuf.Duration`
    * `:null` and `:dyn`
    * `{:list, t}` and `{:map, key, value}`
    * `{:message, name}` — a message type, by its `CEL.TypeProvider`'s
      name for it, such as `:"pkg.Message"`. A declaration may spell it as an
      atom or a string; types CEL returns carry the provider's form.
    * `{:enum, name}` — an enum type, named the same way
    * `{:wrapper, primitive}` — a wrapper message such as
      `google.protobuf.Int64Value` (`{:wrapper, :int}`)
    * `{:optional, t}` — `optional_type(t)`
    * `{:type, t}` — the type of a type value; `:type` alone is
      `{:type, :dyn}` when declaring
    * `{:abstract, name, params}` — any other parameterised type

  """

  alias CEL.Checker.Types, as: CheckerTypes

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
          | {:message, CEL.TypeProvider.name()}
          | {:enum, CEL.TypeProvider.name()}
          | {:optional, t}
          | {:abstract, String.t(), [t]}

  @timestamp {:message, "google.protobuf.Timestamp"}
  @duration {:message, "google.protobuf.Duration"}

  @doc """
  Spells a type as CEL does, for messages to users.

      iex> CEL.Type.format({:map, :string, {:list, :int}})
      "map(string, list(int))"

      iex> CEL.Type.format(:timestamp)
      "google.protobuf.Timestamp"
  """
  @spec format(t) :: String.t()
  def format(type), do: type |> CheckerTypes.from_input() |> CheckerTypes.format()

  # The checker spells timestamp, duration and enums (named in `enums`) as
  # messages, and may leave an unresolved type variable, which is dyn to a
  # reader.
  @doc false
  @spec from_checker(CheckerTypes.t(), MapSet.t(CEL.TypeProvider.name())) :: t
  def from_checker(type, enums \\ MapSet.new())
  def from_checker(@timestamp, _enums), do: :timestamp
  def from_checker(@duration, _enums), do: :duration
  def from_checker({:var, _id}, _enums), do: :dyn
  def from_checker({:type, type}, enums), do: {:type, from_checker(type, enums)}
  def from_checker({:list, elem}, enums), do: {:list, from_checker(elem, enums)}
  def from_checker({:optional, value}, enums), do: {:optional, from_checker(value, enums)}

  def from_checker({:map, key, value}, enums),
    do: {:map, from_checker(key, enums), from_checker(value, enums)}

  def from_checker({:abstract, name, params}, enums),
    do: {:abstract, name, Enum.map(params, &from_checker(&1, enums))}

  def from_checker({:message, name} = type, enums),
    do: if(MapSet.member?(enums, name), do: {:enum, name}, else: type)

  def from_checker(type, _enums), do: type
end

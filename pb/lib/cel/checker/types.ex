defmodule CEL.Checker.Types do
  @moduledoc false

  alias CEL.ProtoType
  alias CEL.WellKnownTypes

  @type primitive :: :bool | :int | :uint | :double | :string | :bytes
  @type var_id :: non_neg_integer
  @type t ::
          :dyn
          | :null
          | primitive
          | {:wrapper, primitive}
          | {:type, t}
          | {:list, t}
          | {:map, t, t}
          | {:message, String.t()}
          | {:optional, t}
          | {:abstract, String.t(), [t]}
          | {:var, var_id}

  @primitive_to_cel %{
    bool: :BOOL,
    int: :INT64,
    uint: :UINT64,
    double: :DOUBLE,
    string: :STRING,
    bytes: :BYTES
  }
  @cel_to_primitive Map.new(@primitive_to_cel, fn {kind, cel} -> {cel, kind} end)
  @numeric [:int, :uint, :double]
  @map_keys [:int, :uint, :bool, :string]

  @spec dyn() :: t
  def dyn, do: :dyn

  @spec null() :: t
  def null, do: :null

  @spec bool() :: t
  def bool, do: :bool

  @spec int() :: t
  def int, do: :int

  @spec uint() :: t
  def uint, do: :uint

  @spec double() :: t
  def double, do: :double

  @spec string() :: t
  def string, do: :string

  @spec bytes() :: t
  def bytes, do: :bytes

  @spec timestamp() :: t
  def timestamp, do: message("google.protobuf.Timestamp")

  @spec duration() :: t
  def duration, do: message("google.protobuf.Duration")

  @spec wrapper(primitive) :: t
  def wrapper(primitive) when primitive in [:bool, :int, :uint, :double, :string, :bytes] do
    {:wrapper, primitive}
  end

  @spec type(t) :: t
  def type(type \\ dyn()), do: {:type, type}

  @spec list(t) :: t
  def list(elem_type \\ dyn()), do: {:list, elem_type}

  @spec map(t, t) :: t
  def map(key_type \\ dyn(), value_type \\ dyn()), do: {:map, key_type, value_type}

  @spec message(String.t()) :: t
  def message(name) when is_binary(name), do: {:message, name}

  @spec optional(t) :: t
  def optional(value_type), do: {:optional, value_type}

  @spec var(var_id) :: t
  def var(id) when is_integer(id) and id >= 0, do: {:var, id}

  @spec from_input(CEL.Type.t() | ProtoType.input() | t) :: t
  def from_input(:dyn), do: dyn()
  def from_input(:null), do: null()
  def from_input(:bool), do: bool()
  def from_input(:int), do: int()
  def from_input(:uint), do: uint()
  def from_input(:double), do: double()
  def from_input(:string), do: string()
  def from_input(:bytes), do: bytes()
  def from_input(:type), do: type()
  def from_input(:timestamp), do: timestamp()
  def from_input(:duration), do: duration()
  def from_input({:enum, name}) when is_binary(name), do: message(name)

  def from_input({:wrapper, primitive} = type)
      when primitive in [:bool, :int, :uint, :double, :string, :bytes], do: type

  def from_input({:type, type}), do: type(from_input(type))
  def from_input({:list, elem_type}), do: list(from_input(elem_type))

  def from_input({:map, key_type, value_type}),
    do: map(from_input(key_type), from_input(value_type))

  def from_input({:message, name}) when is_binary(name), do: message(name)
  def from_input({:optional, value_type}), do: optional(from_input(value_type))

  def from_input({:abstract, name, params}) when is_binary(name) and is_list(params),
    do: {:abstract, name, Enum.map(params, &from_input/1)}

  def from_input({:var, _id} = type), do: type
  def from_input(%{type_kind: {_kind, _value}} = type), do: from_cel(type)

  @spec from_cel(ProtoType.t()) :: t
  def from_cel(%{type_kind: {:dyn, %{}}}), do: dyn()
  def from_cel(%{type_kind: {:null, :NULL_VALUE}}), do: null()

  def from_cel(%{type_kind: {:primitive, primitive}}),
    do: Map.fetch!(@cel_to_primitive, primitive)

  def from_cel(%{type_kind: {:wrapper, primitive}}) do
    primitive = Map.fetch!(@cel_to_primitive, primitive)
    wrapper(primitive)
  end

  def from_cel(%{type_kind: {:well_known, :TIMESTAMP}}), do: timestamp()
  def from_cel(%{type_kind: {:well_known, :DURATION}}), do: duration()

  def from_cel(%{type_kind: {:type, type}}), do: type(from_cel(type))

  def from_cel(%{type_kind: {:list_type, %{elem_type: elem_type}}}) do
    list(from_cel(elem_type))
  end

  def from_cel(%{type_kind: {:map_type, %{key_type: key_type, value_type: value_type}}}) do
    map(from_cel(key_type), from_cel(value_type))
  end

  def from_cel(%{type_kind: {:message_type, name}}), do: message(name)

  def from_cel(%{
        type_kind: {:abstract_type, %{name: "optional_type", parameter_types: [type]}}
      }) do
    optional(from_cel(type))
  end

  def from_cel(%{type_kind: {:abstract_type, %{name: name, parameter_types: params}}}) do
    {:abstract, name, Enum.map(params, &from_cel/1)}
  end

  @spec to_cel(t, %{var_id => t}) :: ProtoType.t()
  def to_cel(type, bindings \\ %{}) do
    case finalize(type, bindings) do
      :dyn ->
        ProtoType.dyn()

      :null ->
        ProtoType.null()

      primitive when is_map_key(@primitive_to_cel, primitive) ->
        ProtoType.coerce(primitive)

      {:wrapper, primitive} ->
        ProtoType.wrapper(Map.fetch!(@primitive_to_cel, primitive))

      {:type, type} ->
        ProtoType.type(to_cel(type, bindings))

      {:list, elem_type} ->
        ProtoType.list(to_cel(elem_type, bindings))

      {:map, key_type, value_type} ->
        ProtoType.map(to_cel(key_type, bindings), to_cel(value_type, bindings))

      {:message, "google.protobuf.Timestamp"} ->
        ProtoType.timestamp()

      {:message, "google.protobuf.Duration"} ->
        ProtoType.duration()

      {:message, name} ->
        ProtoType.message(name)

      {:optional, value_type} ->
        ProtoType.optional(to_cel(value_type, bindings))

      {:abstract, name, params} ->
        ProtoType.abstract(name, Enum.map(params, &to_cel(&1, bindings)))
    end
  end

  @spec finalize(t, %{var_id => t}) :: t
  def finalize(type, bindings \\ %{}) do
    type
    |> resolve(bindings)
    |> dyn_unresolved_vars()
  end

  @spec resolve(t, %{var_id => t}) :: t
  def resolve({:var, id} = var, bindings) do
    case Map.fetch(bindings, id) do
      {:ok, type} -> resolve(type, bindings)
      :error -> var
    end
  end

  def resolve({:type, type}, bindings), do: {:type, resolve(type, bindings)}
  def resolve({:wrapper, _primitive} = type, _bindings), do: type
  def resolve({:list, elem_type}, bindings), do: {:list, resolve(elem_type, bindings)}

  def resolve({:map, key_type, value_type}, bindings) do
    {:map, resolve(key_type, bindings), resolve(value_type, bindings)}
  end

  def resolve({:optional, value_type}, bindings), do: {:optional, resolve(value_type, bindings)}

  def resolve({:abstract, name, params}, bindings),
    do: {:abstract, name, Enum.map(params, &resolve(&1, bindings))}

  def resolve(type, _bindings), do: type

  defp dyn_unresolved_vars({:var, _id}), do: dyn()
  defp dyn_unresolved_vars({:wrapper, _primitive} = type), do: type
  defp dyn_unresolved_vars({:type, type}), do: {:type, dyn_unresolved_vars(type)}
  defp dyn_unresolved_vars({:list, elem_type}), do: {:list, dyn_unresolved_vars(elem_type)}

  defp dyn_unresolved_vars({:map, key_type, value_type}) do
    {:map, dyn_unresolved_vars(key_type), dyn_unresolved_vars(value_type)}
  end

  defp dyn_unresolved_vars({:optional, value_type}),
    do: {:optional, dyn_unresolved_vars(value_type)}

  defp dyn_unresolved_vars({:abstract, name, params}) do
    {:abstract, name, Enum.map(params, &dyn_unresolved_vars/1)}
  end

  defp dyn_unresolved_vars(type), do: type

  @spec dyn?(t) :: boolean
  def dyn?(type), do: type == :dyn

  @spec var?(t) :: boolean
  def var?({:var, _id}), do: true
  def var?(_type), do: false

  @spec optional?(t) :: boolean
  def optional?({:optional, _type}), do: true
  def optional?(_type), do: false

  @spec unwrap_optional(t) :: t
  def unwrap_optional({:optional, type}), do: type
  def unwrap_optional(type), do: type

  @spec wrap_optional(t) :: t
  def wrap_optional({:optional, _type} = type), do: type
  def wrap_optional(type), do: optional(type)

  @spec type_kind(t) :: atom
  def type_kind(:dyn), do: :dyn
  def type_kind(:null), do: :null
  def type_kind(primitive) when is_map_key(@primitive_to_cel, primitive), do: :primitive
  def type_kind({:wrapper, _primitive}), do: :wrapper
  def type_kind({:type, _type}), do: :type
  def type_kind({:list, _type}), do: :list_type
  def type_kind({:map, _key_type, _value_type}), do: :map_type
  def type_kind({:message, _name}), do: :message_type
  def type_kind({:optional, _type}), do: :abstract_type
  def type_kind({:abstract, _name, _params}), do: :abstract_type
  def type_kind({:var, _id}), do: :var

  @spec primitive_kind(t) :: atom | nil
  def primitive_kind(primitive) when is_map_key(@primitive_to_cel, primitive),
    do: Map.fetch!(@primitive_to_cel, primitive)

  def primitive_kind({:wrapper, primitive}), do: Map.fetch!(@primitive_to_cel, primitive)
  def primitive_kind(_type), do: nil

  @spec primitive?(t, atom) :: boolean
  def primitive?(type, primitive), do: primitive_kind(type) == primitive

  @spec numeric?(t) :: boolean
  def numeric?({:wrapper, primitive}), do: primitive in @numeric
  def numeric?(type), do: type in @numeric

  @spec integral?(t) :: boolean
  def integral?({:wrapper, primitive}), do: primitive in [:int, :uint]
  def integral?(type), do: type in [:int, :uint]

  @spec dynamic?(t) :: boolean
  def dynamic?(:dyn), do: true
  def dynamic?({:list, elem_type}), do: dynamic?(elem_type)
  def dynamic?({:map, key_type, value_type}), do: dynamic?(key_type) or dynamic?(value_type)
  def dynamic?({:optional, value_type}), do: dynamic?(value_type)
  def dynamic?(_type), do: false

  @spec dyn_erasure(t) :: t
  def dyn_erasure({:list, _elem_type}), do: list(dyn())
  def dyn_erasure({:map, key_type, _value_type}), do: map(key_type, dyn())
  def dyn_erasure(_type), do: dyn()

  @spec timestamp?(t) :: boolean
  def timestamp?(type), do: type == timestamp()

  @spec duration?(t) :: boolean
  def duration?(type), do: type == duration()

  @spec time?(t) :: boolean
  def time?(type), do: timestamp?(type) or duration?(type)

  @spec map_key?(t) :: boolean
  def map_key?(type), do: type in @map_keys or dyn?(type) or var?(type)

  @spec list_elem(t) :: {:ok, t} | :error
  def list_elem({:list, elem_type}), do: {:ok, elem_type}
  def list_elem(_type), do: :error

  @spec map_types(t) :: {:ok, t, t} | :error
  def map_types({:map, key_type, value_type}), do: {:ok, key_type, value_type}
  def map_types(_type), do: :error

  @spec nullable?(t) :: boolean
  def nullable?(type), do: optional?(type) or type_kind(type) in [:message_type, :wrapper]

  @spec assignable?(t | ProtoType.t(), t | ProtoType.t()) :: boolean
  def assignable?(expected, actual) do
    expected = from_input(expected)
    actual = from_input(actual)

    expected == actual or dyn?(expected) or dyn?(actual) or
      assignable_scalar?(expected, actual) or assignable_composite?(expected, actual)
  end

  @spec common([t | ProtoType.t()]) :: t
  def common([]), do: dyn()

  def common([type | rest]) do
    Enum.reduce(rest, from_input(type), &common_pair(&2, from_input(&1)))
  end

  @spec well_known_assignable?(t | ProtoType.t(), t | ProtoType.t()) :: boolean
  def well_known_assignable?(expected, actual) do
    actual = from_input(actual)

    case from_input(expected) do
      {:message, name} ->
        case WellKnownTypes.field_type(name) do
          {:ok, type} -> assignable?(from_cel(type), actual)
          :error -> false
        end

      _type ->
        false
    end
  end

  @spec value_type(term) :: t
  def value_type(:null), do: null()
  def value_type({:bool, _value}), do: bool()
  def value_type({:int, _value}), do: int()
  def value_type({:uint, _value}), do: uint()
  def value_type({:double, _value}), do: double()
  def value_type({:string, _value}), do: string()
  def value_type({:bytes, _value}), do: bytes()
  def value_type({:timestamp, _value}), do: timestamp()
  def value_type({:duration, _value}), do: duration()
  def value_type({:enum, type, _value}), do: message(type)
  def value_type({:object, type_url, _value}), do: message(WellKnownTypes.type_url_name(type_url))

  def value_type({:list, values}), do: list(values |> Enum.map(&value_type/1) |> common())

  def value_type({:map, values}) do
    map(
      values |> Map.keys() |> Enum.map(&value_type/1) |> common(),
      values |> Map.values() |> Enum.map(&value_type/1) |> common()
    )
  end

  def value_type({:message, name, _fields}) when is_atom(name), do: message(Atom.to_string(name))
  def value_type({:message, name, _fields}), do: message(name)
  def value_type({:optional, :none}), do: optional(dyn())
  def value_type({:optional, {:some, value}}), do: optional(value_type(value))
  def value_type({:type, _type}), do: type()

  @doc """
  The message names a type mentions.
  """
  @spec message_names(t) :: [String.t()]
  def message_names({:message, name}), do: [name]
  def message_names({:wrapper, _primitive}), do: []
  def message_names({:abstract, _name, params}), do: Enum.flat_map(params, &message_names/1)

  def message_names(type) when is_tuple(type),
    do: type |> Tuple.delete_at(0) |> Tuple.to_list() |> Enum.flat_map(&message_names/1)

  def message_names(_type), do: []

  @spec format(t) :: String.t()
  def format(:dyn), do: "dyn"
  def format(:null), do: "null_type"

  def format(primitive) when is_map_key(@primitive_to_cel, primitive),
    do: Atom.to_string(primitive)

  def format({:wrapper, primitive}), do: "wrapper(" <> format(primitive) <> ")"
  def format({:type, type}), do: "type(" <> format(type) <> ")"
  def format({:list, elem_type}), do: "list(" <> format(elem_type) <> ")"

  def format({:map, key_type, value_type}),
    do: "map(" <> format(key_type) <> ", " <> format(value_type) <> ")"

  def format({:message, name}), do: name
  def format({:optional, value_type}), do: "optional_type(" <> format(value_type) <> ")"

  def format({:abstract, name, params}) do
    name <> "(" <> Enum.map_join(params, ", ", &format/1) <> ")"
  end

  def format({:var, id}), do: "$" <> Integer.to_string(id)

  defp assignable_composite?({:list, expected}, {:list, actual}) do
    assignable?(expected, actual)
  end

  defp assignable_composite?(
         {:map, expected_key, expected_value},
         {:map, actual_key, actual_value}
       ) do
    assignable?(expected_key, actual_key) and assignable?(expected_value, actual_value)
  end

  defp assignable_composite?({:optional, expected}, {:optional, actual}) do
    assignable?(expected, actual)
  end

  defp assignable_composite?(
         {:abstract, name, expected_params},
         {:abstract, name, actual_params}
       ) do
    length(expected_params) == length(actual_params) and
      expected_params
      |> Enum.zip(actual_params)
      |> Enum.all?(fn {expected, actual} -> assignable?(expected, actual) end)
  end

  defp assignable_composite?(expected, actual) do
    if contains_var?(expected) or contains_var?(actual) do
      solver_assignable?(expected, actual)
    else
      false
    end
  end

  defp assignable_scalar?(expected, actual) do
    primitive_kind(expected) != nil and primitive_kind(expected) == primitive_kind(actual)
  end

  defp common_pair(type, type), do: type

  defp common_pair(left, right) do
    cond do
      contains_var?(left) or contains_var?(right) -> solver_common([left, right])
      wrapper_primitive_pair?(left, right) -> wrapper(common_wrapper_primitive(left))
      dyn?(left) -> left
      dyn?(right) -> right
      null?(left) and nullable?(right) -> right
      null?(right) and nullable?(left) -> left
      true -> common_composite(left, right)
    end
  end

  defp common_composite({:list, left}, {:list, right}),
    do: list(common_flexible_param(left, right))

  defp common_composite({:map, left_key, left_value}, {:map, right_key, right_value}) do
    map(common_flexible_param(left_key, right_key), common_flexible_param(left_value, right_value))
  end

  defp common_composite({:optional, left}, {:optional, right}),
    do: optional(common_abstract_param(left, right))

  defp common_composite({:abstract, name, left_params}, {:abstract, name, right_params})
       when length(left_params) == length(right_params),
       do: {:abstract, name, Enum.zip_with(left_params, right_params, &common_abstract_param/2)}

  defp common_composite(_left, _right), do: dyn()

  defp common_flexible_param(left, right) do
    cond do
      dyn?(left) -> right
      dyn?(right) -> left
      null?(left) -> right
      null?(right) -> left
      true -> common_pair(left, right)
    end
  end

  defp common_abstract_param(left, right) do
    cond do
      dyn?(left) -> left
      dyn?(right) -> right
      null?(left) -> right
      null?(right) -> left
      true -> common_pair(left, right)
    end
  end

  defp null?(type), do: type_kind(type) == :null

  defp solver_assignable?(expected, actual) do
    match?(
      {:ok, _solver},
      CEL.Checker.Solver.assignable(CEL.Checker.Solver.new(), expected, actual)
    )
  end

  defp solver_common(types) do
    {type, _solver} = CEL.Checker.Solver.common(CEL.Checker.Solver.new(), types)
    type
  end

  defp contains_var?({:var, _id}), do: true
  defp contains_var?({:type, type}), do: contains_var?(type)
  defp contains_var?({:list, elem_type}), do: contains_var?(elem_type)

  defp contains_var?({:map, key_type, value_type}) do
    contains_var?(key_type) or contains_var?(value_type)
  end

  defp contains_var?({:optional, value_type}), do: contains_var?(value_type)
  defp contains_var?({:abstract, _name, params}), do: Enum.any?(params, &contains_var?/1)
  defp contains_var?(_type), do: false

  defp wrapper_primitive_pair?(left, right) do
    (wrapper?(left) and primitive?(right, primitive_kind(left))) or
      (wrapper?(right) and primitive?(left, primitive_kind(right)))
  end

  defp common_wrapper_primitive(type) do
    type
    |> primitive_kind()
    |> then(&Map.fetch!(@cel_to_primitive, &1))
  end

  defp wrapper?({:wrapper, _primitive}), do: true
  defp wrapper?(_type), do: false
end

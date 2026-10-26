defmodule PB.Validate.Path do
  @moduledoc false

  @type field_path :: %{required(:elements) => [map()]}

  @doc false
  @spec field_path(nil | [map()]) :: field_path() | nil
  def field_path(nil), do: nil
  def field_path([]), do: nil
  def field_path(elements) when is_list(elements), do: %{elements: elements}

  @doc false
  @spec field_path([map()], map()) :: field_path() | nil
  def field_path(path, field), do: path |> append_field(field) |> field_path()

  @doc false
  @spec field_path([map()], map(), term) :: field_path() | nil
  def field_path(path, field, subscript),
    do: path |> append_field(field, subscript) |> field_path()

  @doc false
  @spec current_message_field_path([map()]) :: field_path() | nil
  def current_message_field_path(path), do: field_path(path)

  @doc false
  @spec append_field([map()], map()) :: [map()]
  @spec append_field([map()], map(), term) :: [map()]
  def append_field(path, field, subscript \\ nil), do: path ++ [field_element(field, subscript)]

  @doc false
  @spec append_oneof([map()], map()) :: [map()]
  def append_oneof(path, oneof), do: path ++ [oneof_element(oneof)]

  @doc false
  @spec field_element(map()) :: map()
  @spec field_element(map(), term) :: map()
  def field_element(field, subscript \\ nil) do
    %{
      field_number: field.number,
      field_name: Atom.to_string(field.name),
      field_type: path_field_type(field)
    }
    |> maybe_put(:key_type, map_key_type(field))
    |> maybe_put(:value_type, map_value_type(field))
    |> maybe_put(:subscript, subscript)
  end

  @doc false
  @spec oneof_element(map()) :: map()
  def oneof_element(oneof), do: %{field_name: Atom.to_string(oneof.name)}

  @doc false
  @spec rule_element(non_neg_integer, String.t(), atom) :: map()
  @spec rule_element(non_neg_integer, String.t(), atom, term) :: map()
  def rule_element(number, name, type, subscript \\ nil) do
    %{
      field_number: number,
      field_name: name,
      field_type: type
    }
    |> maybe_put(:subscript, subscript)
  end

  @doc false
  @spec rule_field_element(map()) :: map()
  def rule_field_element(field) do
    rule_element(field.number, rule_field_name(field), field.source.type)
  end

  @doc false
  @spec map_subscript(map(), term) ::
          {:bool_key, boolean}
          | {:int_key, integer}
          | {:uint_key, non_neg_integer}
          | {:string_key, String.t()}
          | nil
  def map_subscript(%{type: :TYPE_BOOL}, key) when is_boolean(key), do: {:bool_key, key}

  def map_subscript(%{type: type}, key)
      when type in [
             :TYPE_INT32,
             :TYPE_INT64,
             :TYPE_SINT32,
             :TYPE_SINT64,
             :TYPE_SFIXED32,
             :TYPE_SFIXED64
           ] and is_integer(key),
      do: {:int_key, key}

  def map_subscript(%{type: type}, key)
      when type in [:TYPE_UINT32, :TYPE_UINT64, :TYPE_FIXED32, :TYPE_FIXED64] and
             is_integer(key),
      do: {:uint_key, key}

  def map_subscript(%{type: :TYPE_STRING}, key) when is_binary(key), do: {:string_key, key}
  def map_subscript(_field, _key), do: nil

  @doc false
  @spec api_path(nil | field_path() | [map() | PB.Error.path_element()]) :: [
          PB.Error.path_element()
        ]
  def api_path(nil), do: []
  def api_path(%{elements: elements}), do: api_path(elements)
  def api_path(elements) when is_list(elements), do: Enum.flat_map(elements, &api_path_element/1)

  @doc false
  @spec api_path([map() | PB.Error.path_element()], map()) :: [PB.Error.path_element()]
  def api_path(path, field), do: api_path(path) ++ [field.name]

  @doc false
  @spec canonical_field_path(field_path() | nil | map()) :: field_path() | nil | map()
  def canonical_field_path(nil), do: nil

  def canonical_field_path(%{elements: elements} = field) when is_list(elements) do
    %{field | elements: Enum.map(elements, &canonical_field_element/1)}
  end

  def canonical_field_path(field), do: field

  defp path_field_type(%{encoding: :delimited}), do: :TYPE_GROUP
  defp path_field_type(field), do: field.source.type

  defp map_key_type(%{cardinality: :map, map_key: key}), do: key.source.type
  defp map_key_type(_field), do: nil

  defp map_value_type(%{cardinality: :map, map_value: value}), do: value.source.type
  defp map_value_type(_field), do: nil

  defp rule_field_name(%{kind: :extension, name: name}), do: "[#{Atom.to_string(name)}]"
  defp rule_field_name(%{name: name}), do: Atom.to_string(name)

  defp api_path_element(%{field_name: name} = element) do
    field = api_field_name(name)

    case Map.get(element, :subscript) do
      nil -> [field]
      subscript -> [field, api_subscript(subscript)]
    end
  end

  defp api_path_element(element), do: [element]

  defp api_field_name(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  defp api_field_name(name), do: name

  defp api_subscript({:index, index}), do: {:index, index}

  defp api_subscript({kind, key}) when kind in [:bool_key, :int_key, :uint_key, :string_key],
    do: {:key, key}

  defp api_subscript(other), do: other

  defp canonical_field_element(%{subscript: _subscript} = element), do: element

  defp canonical_field_element(element) when is_map(element) do
    Map.drop(element, [:key_type, :value_type])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

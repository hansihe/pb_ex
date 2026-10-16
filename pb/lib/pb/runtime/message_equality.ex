defmodule PB.Runtime.MessageEquality do
  @moduledoc false

  alias PB.Runtime.Scalar
  alias PB.Runtime.MessageView
  alias PB.Runtime.Schema
  alias PB.UnknownField

  @message_types [:TYPE_MESSAGE, :TYPE_GROUP]
  @float_types [:TYPE_FLOAT, :TYPE_DOUBLE]
  @extension_key :__extensions__
  @message_name_key :__message_name__

  # The comparison tree below returns plain booleans through short-circuiting
  # `Enum.all?`, so it can't thread `{:error, _}` tuples without becoming
  # unreadable. Instead, an input that isn't a valid term for its message type
  # (adapter/struct/representation projection failure, missing nested type) is
  # `halt/1`-ed and caught at the `equal?/4` boundary, which surfaces it as
  # `{:error, reason}`. Callers treat that as a contract failure, not "unequal".
  @throw_tag :pb_message_equal_error

  @type result :: {:ok, boolean()} | {:error, term()}

  @spec equal?(PB.schema(), PB.Schema.Compiled.message_name(), term(), term()) :: result
  def equal?(schema, message_name, left, right)
      when is_atom(message_name) do
    with {:ok, msg} <- Schema.fetch_message(schema, message_name),
         {:ok, left} <- MessageView.to_proto_fields(schema, message_name, msg, left, []),
         {:ok, right} <- MessageView.to_proto_fields(schema, message_name, msg, right, []) do
      {:ok, message_fields_equal?(schema, msg, left, right)}
    end
  catch
    {@throw_tag, reason} -> {:error, reason}
  end

  def equal?(_schema, _message_name, _left, _right), do: {:ok, false}

  defp halt(reason), do: throw({@throw_tag, reason})

  defp message_fields_equal?(schema, msg, left, right) do
    unknown_fields_equal?(left, right) and
      extension_fields_equal?(left, right) and
      extra_storage_fields(msg, left) == extra_storage_fields(msg, right) and
      Enum.all?(msg.fields_by_name, fn {field, info} ->
        field_equal?(schema, msg, left, right, field, info)
      end)
  end

  defp field_equal?(schema, msg, left, right, field, info) do
    left_present? = present?(msg, left, field, info)
    right_present? = present?(msg, right, field, info)

    cond do
      presence_tracked?(info) and left_present? != right_present? ->
        false

      presence_tracked?(info) and not left_present? ->
        true

      true ->
        with {:ok, left} <- value_or_default(msg, left, field, info),
             {:ok, right} <- value_or_default(msg, right, field, info) do
          value_equal?(schema, info, left, right)
        else
          {:error, reason} -> halt(reason)
        end
    end
  end

  defp value_or_default(msg, fields, field, info) do
    case fetch(msg, fields, field, info) do
      {:ok, value} -> {:ok, value}
      :error -> default_value(info)
    end
  end

  defp default_value(%{cardinality: :repeated}), do: {:ok, []}
  defp default_value(%{cardinality: :map}), do: {:ok, %{}}
  defp default_value(field), do: Scalar.default_value(field, [])

  defp value_equal?(schema, %{cardinality: :repeated} = field, left, right)
       when is_list(left) and is_list(right) and length(left) == length(right) do
    Enum.zip(left, right)
    |> Enum.all?(fn {left, right} -> singular_value_equal?(schema, field, left, right) end)
  end

  defp value_equal?(_schema, %{cardinality: :repeated}, left, right)
       when is_list(left) and is_list(right),
       do: false

  defp value_equal?(schema, %{cardinality: :map, map_value: value_field}, left, right)
       when is_map(left) and is_map(right) and map_size(left) == map_size(right) do
    Enum.all?(left, fn {key, left_value} ->
      case Map.fetch(right, key) do
        {:ok, right_value} -> singular_value_equal?(schema, value_field, left_value, right_value)
        :error -> false
      end
    end)
  end

  defp value_equal?(_schema, %{cardinality: :map}, left, right)
       when is_map(left) and is_map(right),
       do: false

  defp value_equal?(schema, field, left, right) do
    singular_value_equal?(schema, field, left, right)
  end

  defp singular_value_equal?(schema, %{type: type, type_name: type_name}, left, right)
       when type in @message_types do
    case equal?(schema, type_name, left, right) do
      {:ok, equal?} -> equal?
      {:error, reason} -> halt(reason)
    end
  end

  defp singular_value_equal?(_schema, %{type: type}, left, right) when type in @float_types do
    left != :nan and right != :nan and left == right
  end

  defp singular_value_equal?(_schema, %{type: :TYPE_ENUM} = field, left, right) do
    enum_number(field, left) == enum_number(field, right)
  end

  defp singular_value_equal?(_schema, _field, left, right), do: left == right

  defp enum_number(%{enum: %{by_name: by_name}}, value) when is_atom(value) do
    Map.get(by_name, value, value)
  end

  defp enum_number(_field, value), do: value

  defp fetch(msg, fields, field, info) when is_map(fields) and is_atom(field) do
    case Map.fetch(fields, field) do
      {:ok, value} -> {:ok, value}
      :error -> fetch_oneof(msg, fields, field, info)
    end
  end

  defp present?(msg, fields, field, info),
    do: match?({:ok, _value}, fetch(msg, fields, field, info))

  defp fetch_oneof(msg, fields, field, %{presence: :oneof, oneof_index: index}) do
    with %{name: oneof_name} <- msg.oneofs[index],
         {:ok, {^field, value}} <- Map.fetch(fields, oneof_name) do
      {:ok, value}
    else
      _other -> :error
    end
  end

  defp fetch_oneof(_msg, _fields, _field, _info), do: :error

  defp presence_tracked?(%{presence: presence}), do: presence in [:explicit, :required, :oneof]
  defp presence_tracked?(_field), do: false

  defp extra_storage_fields(msg, fields) do
    Map.drop(fields, known_storage_keys(msg))
  end

  defp known_storage_keys(msg) do
    oneof_names = Enum.map(msg.oneofs, fn {_index, oneof} -> oneof.name end)

    [
      UnknownField.key(),
      @extension_key,
      @message_name_key | Map.keys(msg.fields_by_name) ++ oneof_names
    ]
  end

  defp extension_fields_equal?(left, right) do
    Map.get(left, @extension_key, %{}) == Map.get(right, @extension_key, %{})
  end

  defp unknown_fields_equal?(left, right) do
    left_unknown = left |> Map.get(UnknownField.key(), []) |> Enum.map(& &1.raw)
    right_unknown = right |> Map.get(UnknownField.key(), []) |> Enum.map(& &1.raw)
    left_unknown == right_unknown
  end
end

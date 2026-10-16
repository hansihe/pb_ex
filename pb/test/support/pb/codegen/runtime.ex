defmodule PB.Codegen.Runtime do
  @moduledoc """
  Runtime helpers shared by code emitted from `PB.Codegen`.

  Generated code should use `PB.Wire` for protobuf wire primitives. This
  module contains glue that keeps generated code aligned with PB's runtime
  error contract.
  """

  alias PB.Runtime.Errors
  alias PB.Runtime.Scalar
  alias PB.UnknownField
  alias PB.Wire

  @message_name_key :__message_name__

  def normalize_encode_result(result, message_name) do
    Errors.normalize_result(result, :encode, message_name)
  end

  def normalize_decode_result(result, message_name) do
    Errors.normalize_result(result, :decode, message_name)
  end

  # TODO(codegen): This mirrors PB.Runtime.Encoder option normalization.
  # Generated code should consume the same encode option contract/plan as the
  # dynamic runtime instead of carrying a parallel copy.
  def normalize_encode_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      unknown = Keyword.keys(opts) -- [:unknown_fields]

      cond do
        unknown != [] ->
          {:error, {:unknown_options, unknown}}

        (mode = Keyword.get(opts, :unknown_fields, :error)) in [:error, :ignore] ->
          {:ok, %{unknown_fields: mode}}

        true ->
          {:error, {:invalid_option, :unknown_fields, Keyword.get(opts, :unknown_fields)}}
      end
    else
      {:error, {:invalid_options, Errors.type_of(opts)}}
    end
  end

  def normalize_encode_opts(opts), do: {:error, {:invalid_options, Errors.type_of(opts)}}

  def validate_encode_message(nil, _path), do: {:error, :absent}

  def validate_encode_message(data, _path) when is_map(data) and not is_struct(data), do: :ok

  def validate_encode_message(data, path) do
    {:error, {:invalid_value, path, :map, Errors.type_of(data)}}
  end

  def validate_encode_known_fields(
        data,
        protobuf_message,
        fields,
        oneof_members,
        oneofs,
        path,
        opts
      ) do
    Enum.reduce_while(data, :ok, fn {key, value}, :ok ->
      cond do
        key in fields ->
          if key in oneof_members do
            {:halt, {:error, {:invalid_oneof, path ++ [key], :oneof_member_must_use_wrapper}}}
          else
            {:cont, :ok}
          end

        key in oneofs ->
          {:cont, :ok}

        key == UnknownField.key() ->
          case UnknownField.encode_all(value) do
            {:ok, _raw} -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end

        key == @message_name_key and value == protobuf_message ->
          {:cont, :ok}

        key == @message_name_key ->
          {:halt,
           {:error,
            {:message_name_mismatch, path ++ [@message_name_key], protobuf_message, value}}}

        opts.unknown_fields == :ignore ->
          {:cont, :ok}

        true ->
          {:halt, {:error, {:unknown_field, protobuf_message, path ++ [key]}}}
      end
    end)
  end

  def validate_encode_required_fields(data, required_fields, path) do
    Enum.reduce_while(required_fields, :ok, fn {name, type}, :ok ->
      cond do
        not Map.has_key?(data, name) ->
          {:halt, {:error, {:missing_required, path ++ [name]}}}

        type == :TYPE_MESSAGE and Map.get(data, name) == nil ->
          {:halt, {:error, {:missing_required, path ++ [name]}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  def encode_fields(data, path, opts, acc, steps) do
    Enum.reduce_while(steps, {:ok, acc}, fn step, {:ok, acc} ->
      case step.(data, acc, path, opts) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, :absent} -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def finish_encode_fields(fields, unknowns \\ []) do
    with {:ok, unknowns} <- UnknownField.encode_all(unknowns) do
      fields =
        fields
        |> Enum.sort_by(fn {number, _encoded} -> number end)
        |> Enum.flat_map(fn {_number, encoded} -> encoded end)

      {:ok, [fields | unknowns]}
    end
  end

  def encode_repeated(values, path, encode_one) when is_list(values) do
    with {:ok, encoded} <-
           values
           |> Enum.with_index()
           |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
             value_path = path ++ [{:index, index}]

             case encode_one.(value, value_path) do
               {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
               {:error, :absent} -> {:cont, {:ok, acc}}
               {:error, _reason} = error -> {:halt, error}
             end
           end) do
      {:ok, Enum.reverse(encoded)}
    end
  end

  def encode_repeated(nil, _path, _encode_one), do: {:ok, []}

  def encode_repeated(values, path, _encode_one) do
    {:error, {:invalid_value, path, :list, Errors.type_of(values)}}
  end

  def encode_map(entries, path, encode_entry) when is_map(entries) and not is_struct(entries) do
    with {:ok, encoded} <-
           Enum.reduce_while(entries, {:ok, []}, fn {key, value}, {:ok, acc} ->
             entry_path = path ++ [{:key, key}]
             entry = %{key: key, value: value}

             case encode_entry.(entry, entry_path) do
               {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
               {:error, :absent} -> {:cont, {:ok, acc}}
               {:error, _reason} = error -> {:halt, error}
             end
           end) do
      {:ok, Enum.reverse(encoded)}
    end
  end

  def encode_map(nil, _path, _encode_entry), do: {:ok, []}

  def encode_map(value, path, _encode_entry) do
    {:error, {:invalid_value, path, :map, Errors.type_of(value)}}
  end

  def encode_packed([], _field, _path), do: {:ok, []}
  def encode_packed(nil, _field, _path), do: {:ok, []}

  def encode_packed(values, field, path) when is_list(values) do
    with {:ok, encoded} <-
           values
           |> Enum.with_index()
           |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
             value_path = path ++ [{:index, index}]

             case encode_scalar_value(field, value, value_path) do
               {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
               {:error, _reason} = error -> {:halt, error}
             end
           end) do
      encoded = Enum.reverse(encoded)

      {:ok,
       [
         Wire.encode_tag(field.number, 2),
         Wire.encode_varint(IO.iodata_length(encoded))
         | encoded
       ]}
    end
  end

  def encode_packed(values, _field, path) do
    {:error, {:invalid_value, path, :list, Errors.type_of(values)}}
  end

  def skip_encode_field?(%{type: :TYPE_MESSAGE}, _value), do: false

  def skip_encode_field?(field, value) do
    with {:ok, value} <- Scalar.normalize_encode_value(field, value, []) do
      Scalar.implicit_presence?(field) and Scalar.default_value?(field, value)
    else
      {:error, _reason} -> false
    end
  end

  def encode_tagged(field, body) do
    {:ok, [Wire.encode_tag(field.number, field.wire_type) | body]}
  end

  def encode_message_value(field, body) do
    {:ok, Wire.encode_message_value(field.number, field.encoding, body)}
  end

  def encode_typed_value(field, value, path), do: Scalar.encode(field, value, path)

  def encode_scalar_value(field, value, path), do: Scalar.encode(field, value, path)

  def decode_error_at(%{__exception__: true} = error, _path), do: {:error, error}

  def decode_error_at(reason, path) do
    {:error, reason |> Errors.to_error(:decode) |> PB.Error.prepend_path(path)}
  end

  def decode_field_error(%{__exception__: true} = error, _path), do: {:error, error}

  def decode_field_error(
        {:adapter_error, _fqn, _direction, _adapter_path, _reason} = reason,
        _current_path
      ) do
    {:error, Errors.to_error(reason, :decode)}
  end

  def decode_field_error(reason, path), do: decode_error_at(reason, path)

  # TODO(codegen): This is the generated-code twin of Runtime.Decoder
  # post-processing. Collapse maps, oneof wrapping, default application, and
  # required checks should come from a shared decode plan.
  def post_process_decode(acc, spec, path) do
    with {:ok, acc} <- collapse_maps(acc, spec.maps, path) do
      acc =
        spec.reverse
        |> Enum.reduce(acc, fn name, acc -> reverse_repeated(acc, name) end)
        |> UnknownField.reverse_all()

      with :ok <- ensure_required(acc, spec.required, path) do
        acc =
          acc
          |> wrap_oneofs(spec.oneofs)
          |> apply_decode_defaults(spec.defaults)

        {:ok, acc}
      end
    end
  end

  defp ensure_required(acc, required, path) do
    Enum.reduce_while(required, :ok, fn name, :ok ->
      if Map.has_key?(acc, name) do
        {:cont, :ok}
      else
        {:halt, {:error, {:missing_required, path ++ [name]}}}
      end
    end)
  end

  def reverse_repeated(acc, name) do
    case Map.fetch(acc, name) do
      {:ok, list} -> Map.put(acc, name, Enum.reverse(list))
      :error -> acc
    end
  end

  def collapse_map(acc, name, key_field, value_field, path) do
    case Map.fetch(acc, name) do
      {:ok, list} ->
        case collapse_map_values(list, key_field, value_field, path ++ [name]) do
          {:ok, map} -> {:ok, Map.put(acc, name, map)}
          {:error, _reason} = error -> error
        end

      :error ->
        {:ok, acc}
    end
  end

  def wrap_oneofs(acc, oneofs) do
    Enum.reduce(oneofs, acc, fn {oneof_name, fields}, acc ->
      wrap_oneof(acc, oneof_name, fields)
    end)
  end

  defp wrap_oneof(acc, oneof_name, fields) do
    Enum.reduce_while(fields, acc, fn field_name, acc ->
      if Map.has_key?(acc, field_name) do
        acc =
          acc
          |> Map.put(oneof_name, {field_name, Map.fetch!(acc, field_name)})
          |> Map.delete(field_name)

        {:halt, acc}
      else
        {:cont, acc}
      end
    end)
  end

  defp collapse_maps(acc, maps, path) do
    Enum.reduce_while(maps, {:ok, acc}, fn {name, key_field, value_field}, {:ok, acc} ->
      case collapse_map(acc, name, key_field, value_field, path) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp collapse_map_values(values, key_field, value_field, path) do
    values
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {entry, index}, {:ok, acc} ->
      entry_path = path ++ [{:index, index}]

      with {:ok, key} <- map_entry_value(entry, :key, key_field, entry_path ++ [:key]),
           {:ok, value} <- map_entry_value(entry, :value, value_field, entry_path ++ [:value]) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, reason} -> {:halt, decode_field_error(reason, entry_path)}
      end
    end)
  end

  defp map_entry_value(entry, key, field, path) do
    case Map.fetch(entry, key) do
      {:ok, value} -> {:ok, value}
      :error -> Scalar.default_value(field, path)
    end
  end

  defp apply_decode_defaults(acc, defaults) do
    Enum.reduce(defaults, acc, fn {name, value}, acc ->
      Map.put_new(acc, name, value)
    end)
  end
end

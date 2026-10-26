defmodule PB.Runtime.Decoder.Scan do
  @moduledoc false

  # Wire-format scanner for runtime decode.
  #
  # This module performs the first decode phase. It walks the input bytes once,
  # checks wire compatibility, decodes scalar values, recursively scans embedded
  # messages, and accumulates field occurrences in a private decode accumulator.
  #
  # The accumulator intentionally is not the public message shape. Repeated and
  # map occurrences are stored in reverse wire order so appending stays constant
  # time. Singular scalar fields keep the last value. Singular message fields
  # merge their scanned child accumulators, which matches protobuf's
  # "last write wins except messages merge" decode rule. Unknown fields are kept
  # in reverse wire order under the `:__unknown_fields__` map key, and extension
  # values are kept under the `:__extensions__` map key with the same occurrence
  # shapes as regular fields.
  #
  # `PB.Runtime.Decoder.Finalize` owns the second phase: reversing repeated
  # data, collapsing map entries, applying defaults, wrapping oneofs, adapter
  # projection, and validation that depends on final protobuf semantics.

  import Bitwise

  alias PB.Runtime.Errors
  alias PB.Runtime.Scalar
  alias PB.Runtime.Schema, as: RuntimeSchema
  alias PB.Schema.Features
  alias PB.UnknownField
  alias PB.Wire

  @max_decode_depth Wire.max_decode_depth()
  @extension_key :__extensions__
  @unknown_key :__unknown_fields__

  @typedoc "Current protobuf path used for decode errors."
  @type path :: [PB.Error.path_element()]

  @typedoc "Normalized runtime decode options."
  @type opts :: %{
          required(:defaults) => boolean(),
          required(:message_names) => nil | :root
        }

  @typedoc "Where a decoded field occurrence is stored in the accumulator."
  @type storage :: :field | :extension

  @typedoc "Regular field name in a compiled message."
  @type field_name :: atom()

  @typedoc "Fully-qualified extension field name."
  @type extension_name :: atom()

  @typedoc "Accumulator key used for preserved unknown fields."
  @type unknown_key :: :__unknown_fields__

  @typedoc "Accumulator key used for decoded extension fields."
  @type extension_key :: :__extensions__

  @typedoc "Decoded scalar value before final default elision."
  @type scalar_value :: integer() | float() | boolean() | binary() | atom()

  @typedoc "Scanned embedded message accumulator."
  @type message_acc :: %{
          optional(field_name()) => occurrence_value(),
          optional(unknown_key()) => [UnknownField.t()],
          optional(extension_key()) => extension_acc()
        }

  @typedoc "Decoded extension field accumulator."
  @type extension_acc :: %{optional(extension_name()) => occurrence_value()}

  @typedoc """
  Stored field value after scanning.

  Repeated fields and maps use lists in reverse wire order. Singular message
  fields use `message_acc/0`; singular scalar fields use `scalar_value/0`.
  """
  @type occurrence_value :: scalar_value() | message_acc() | [scalar_value() | message_acc()]

  @typedoc "Runtime decode scan accumulator."
  @type t :: message_acc()

  @spec fields(
          PB.schema(),
          PB.Schema.Compiled.message(),
          binary(),
          non_neg_integer(),
          opts(),
          path()
        ) ::
          {:ok, t(), binary()} | {:error, PB.Error.t()}
  def fields(schema, msg, bin, depth, opts, path) do
    extensions_by_number = msg.extensions_by_number

    if map_size(extensions_by_number) == 0 do
      decode_regular_fields(schema, msg, bin, %{}, depth, opts, path)
    else
      decode_extensible_fields(schema, msg, extensions_by_number, bin, %{}, depth, opts, path)
    end
  end

  defp decode_regular_fields(_schema, _msg, <<>>, acc, _depth, _opts, _path),
    do: {:ok, acc, <<>>}

  defp decode_regular_fields(schema, msg, bin, acc, depth, opts, path) do
    with {:ok, tag_val, rest} <- Wire.decode_tag(bin),
         fnum = tag_val >>> 3,
         wtype = tag_val &&& 0x07,
         :ok <- Wire.validate_field_number(fnum),
         :ok <- Wire.validate_wire_type(wtype) do
      case msg.fields_by_number[fnum] do
        nil ->
          with {:ok, acc, rest} <- decode_unknown_field(fnum, wtype, rest, acc, path) do
            decode_regular_fields(schema, msg, rest, acc, depth, opts, path)
          end

        field ->
          with {:ok, acc, rest} <-
                 decode_known_field(
                   schema,
                   msg,
                   field,
                   wtype,
                   rest,
                   acc,
                   depth,
                   opts,
                   path,
                   :field
                 ) do
            decode_regular_fields(schema, msg, rest, acc, depth, opts, path)
          end
      end
    else
      {:error, reason} -> decode_error_at(reason, path)
    end
  end

  defp decode_extensible_fields(
         _schema,
         _msg,
         _extensions_by_number,
         <<>>,
         acc,
         _depth,
         _opts,
         _path
       ),
       do: {:ok, acc, <<>>}

  defp decode_extensible_fields(schema, msg, extensions_by_number, bin, acc, depth, opts, path) do
    with {:ok, tag_val, rest} <- Wire.decode_tag(bin),
         fnum = tag_val >>> 3,
         wtype = tag_val &&& 0x07,
         :ok <- Wire.validate_field_number(fnum),
         :ok <- Wire.validate_wire_type(wtype) do
      case msg.fields_by_number[fnum] do
        nil ->
          case extensions_by_number[fnum] do
            nil ->
              with {:ok, acc, rest} <- decode_unknown_field(fnum, wtype, rest, acc, path) do
                decode_extensible_fields(
                  schema,
                  msg,
                  extensions_by_number,
                  rest,
                  acc,
                  depth,
                  opts,
                  path
                )
              end

            extension ->
              with {:ok, acc, rest} <-
                     decode_known_field(
                       schema,
                       msg,
                       extension,
                       wtype,
                       rest,
                       acc,
                       depth,
                       opts,
                       path,
                       :extension
                     ) do
                decode_extensible_fields(
                  schema,
                  msg,
                  extensions_by_number,
                  rest,
                  acc,
                  depth,
                  opts,
                  path
                )
              end
          end

        field ->
          with {:ok, acc, rest} <-
                 decode_known_field(
                   schema,
                   msg,
                   field,
                   wtype,
                   rest,
                   acc,
                   depth,
                   opts,
                   path,
                   :field
                 ) do
            decode_extensible_fields(
              schema,
              msg,
              extensions_by_number,
              rest,
              acc,
              depth,
              opts,
              path
            )
          end
      end
    else
      {:error, reason} -> decode_error_at(reason, path)
    end
  end

  # A known field with a wire type it cannot have is kept as an unknown field,
  # as C++ and Go do.
  defp decode_known_field(schema, msg, field, wtype, rest, acc, depth, opts, path, storage) do
    cond do
      packed_wire?(field, wtype) ->
        decode_packed_field(schema, field, rest, acc, path, storage)

      wtype == field.wire_type ->
        decode_unpacked_field(schema, msg, field, wtype, rest, acc, depth, opts, path, storage)

      true ->
        decode_unknown_field(field.number, wtype, rest, acc, path)
    end
  end

  defp decode_unknown_field(fnum, wtype, rest, acc, path) do
    case Wire.read_unknown_field(fnum, wtype, rest) do
      {:ok, raw, rest} ->
        {:ok, UnknownField.append(acc, UnknownField.from_raw(fnum, wtype, raw)), rest}

      {:error, reason} ->
        decode_error_at(reason, path)
    end
  end

  defp decode_packed_field(_schema, field, rest, acc, path, storage) do
    field_path = path ++ field_path(field, storage)

    with {:ok, raw, rest} <- Wire.read_wire_raw(2, rest),
         {:ok, packed, <<>>} <- Wire.read_wire(2, raw),
         {:ok, values, unknowns} <- decode_packed_values(field, packed, field_path) do
      # `values` is already in reverse-storage order (see decode_packed_values),
      # matching the element-by-element repeated path, so it stores directly —
      # no reversal here, and store_repeated_values copies nothing on the first
      # (canonical) occurrence.
      acc =
        if values == [],
          do: acc,
          else: store_repeated_values(acc, field, values, storage)

      acc = Enum.reduce(unknowns, acc, &UnknownField.append(&2, &1))
      {:ok, acc, rest}
    else
      {:error, reason} -> decode_error_at(reason, field_path)
    end
  end

  defp decode_unpacked_field(
         schema,
         msg,
         %{cardinality: :map, map_entry: entry} = field,
         wtype,
         rest,
         acc,
         depth,
         opts,
         path,
         storage
       ) do
    value_path = decode_value_path(acc, field, path, storage)

    with {:ok, raw_body, body, rest} <- read_field_value(field, wtype, rest) do
      case decode_map_entry(schema, entry, body, depth, opts, value_path) do
        {:ok, entry_acc} ->
          {:ok, store_decoded_value(schema, acc, msg, field, entry_acc, storage), rest}

        :closed_enum_value ->
          unknown = UnknownField.from_raw(field.number, wtype, raw_body)
          {:ok, UnknownField.append(acc, unknown), rest}

        {:error, error} ->
          {:error, error}
      end
    else
      {:error, reason} -> decode_error_at(reason, value_path)
    end
  end

  defp decode_unpacked_field(
         schema,
         msg,
         %{type: :TYPE_MESSAGE} = field,
         wtype,
         rest,
         acc,
         depth,
         opts,
         path,
         storage
       ) do
    value_path = decode_value_path(acc, field, path, storage)

    with {:ok, _raw_body, raw, rest} <- read_field_value(field, wtype, rest) do
      case interpret(schema, field, raw, depth, opts, value_path) do
        {:ok, value} ->
          {:ok, store_decoded_value(schema, acc, msg, field, value, storage), rest}

        {:error, reason} ->
          decode_error_at(reason, value_path)
      end
    else
      {:error, reason} -> decode_error_at(reason, value_path)
    end
  end

  defp decode_unpacked_field(schema, msg, field, wtype, rest, acc, _depth, _opts, path, storage) do
    with {:ok, raw_body, raw, rest} <- read_field_value(field, wtype, rest) do
      case Scalar.decode(field, raw) do
        {:ok, value} ->
          {:ok, store_decoded_value(schema, acc, msg, field, value, storage), rest}

        {:error, {:closed_enum_value, _raw}} ->
          unknown = UnknownField.from_raw(field.number, wtype, raw_body)
          {:ok, UnknownField.append(acc, unknown), rest}

        {:error, reason} ->
          decode_error_at(reason, decode_value_path(acc, field, path, storage))
      end
    else
      {:error, reason} -> decode_error_at(reason, decode_value_path(acc, field, path, storage))
    end
  end

  defp packed_wire?(field, 2),
    do: field.cardinality == :repeated and Wire.packable_type?(field.type)

  defp packed_wire?(_field, _wtype), do: false

  defp read_field_value(%{type: :TYPE_MESSAGE, encoding: encoding} = field, _wtype, rest) do
    with {:ok, body, raw_body, rest} <- Wire.read_message_field(field.number, encoding, rest) do
      {:ok, raw_body, body, rest}
    end
  end

  defp read_field_value(_field, wtype, rest) do
    with {:ok, raw_body, rest} <- Wire.read_wire_raw(wtype, rest),
         {:ok, raw, <<>>} <- Wire.read_wire(wtype, raw_body) do
      {:ok, raw_body, raw, rest}
    end
  end

  # The element index is built into the error path eagerly per element but only
  # ever read when an error is rendered. Capturing the accumulator list (O(1)) as
  # a deferred `{:index_of, list}` marker — resolved to `{:index, length(list)}`
  # in decode_error_at — keeps the happy path O(1) per element instead of O(n)
  # (length over the growing list), avoiding O(n²) decode of large repeated/map
  # fields. Immutability makes the deferral exact: the captured list's length is
  # frozen at this point regardless of later prepends.
  defp decode_value_path(acc, %{cardinality: cardinality, name: name}, path, :field)
       when cardinality in [:repeated, :map] do
    path ++ [name, {:index_of, Map.get(acc, name, [])}]
  end

  defp decode_value_path(acc, %{cardinality: cardinality, name: name}, path, :extension)
       when cardinality in [:repeated, :map] do
    extensions = Map.get(acc, @extension_key, %{})
    path ++ [@extension_key, name, {:index_of, Map.get(extensions, name, [])}]
  end

  defp decode_value_path(_acc, field, path, storage), do: path ++ field_path(field, storage)

  defp field_path(field, :field), do: [field.name]
  defp field_path(field, :extension), do: [@extension_key, field.name]

  defp store_repeated_values(acc, field, values, :field) do
    Map.update(acc, field.name, values, &(values ++ &1))
  end

  defp store_repeated_values(acc, field, values, :extension) do
    update_extension(acc, field.name, values, &(values ++ &1))
  end

  defp store_decoded_value(schema, acc, msg, field, value, :field) do
    if Features.repeated?(field) do
      Map.update(acc, field.name, [value], &[value | &1])
    else
      acc
      |> maybe_clear_oneof_siblings(msg, field)
      |> Map.update(field.name, value, &merge_singular_value(schema, field, &1, value))
    end
  end

  defp store_decoded_value(schema, acc, _msg, field, value, :extension) do
    if Features.repeated?(field),
      do: update_extension(acc, field.name, [value], &[value | &1]),
      else:
        update_extension(acc, field.name, value, &merge_singular_value(schema, field, &1, value))
  end

  defp update_extension(fields, name, initial, fun) do
    Map.update(fields, @extension_key, %{name => initial}, fn extensions ->
      Map.update(extensions, name, initial, fun)
    end)
  end

  # Singular message occurrences merge at scan time so finalization can validate
  # the post-merge presence state. Repeated fields and maps keep each occurrence
  # distinct; map duplicate-key replacement is a finalization concern.
  defp merge_singular_value(schema, %{type: :TYPE_MESSAGE} = field, left, right) do
    case schema.messages[field.type_name] do
      nil -> right
      ref -> merge_message_acc(schema, ref, left, right)
    end
  end

  defp merge_singular_value(_schema, _field, _left, right), do: right

  defp merge_message_acc(schema, msg, left, right) do
    Enum.reduce(right, left, fn
      {@unknown_key, right_unknowns}, acc ->
        Map.update(acc, @unknown_key, right_unknowns, &(right_unknowns ++ &1))

      {@extension_key, right_extensions}, acc ->
        merge_extension_acc(schema, msg, acc, right_extensions)

      {name, right_value}, acc ->
        field = Map.fetch!(msg.fields_by_name, name)

        acc
        |> maybe_clear_oneof_siblings(msg, field)
        |> Map.update(name, right_value, &merge_field_acc_value(schema, field, &1, right_value))
    end)
  end

  defp merge_extension_acc(schema, msg, acc, right_extensions) do
    Map.update(acc, @extension_key, right_extensions, fn left_extensions ->
      Enum.reduce(right_extensions, left_extensions, fn {name, right_value}, extensions ->
        field = Map.fetch!(msg.extensions_by_name, name)

        Map.update(
          extensions,
          name,
          right_value,
          &merge_field_acc_value(schema, field, &1, right_value)
        )
      end)
    end)
  end

  defp merge_field_acc_value(_schema, %{cardinality: cardinality}, left, right)
       when cardinality in [:repeated, :map],
       do: right ++ left

  defp merge_field_acc_value(schema, field, left, right),
    do: merge_singular_value(schema, field, left, right)

  defp maybe_clear_oneof_siblings(acc, msg, field) do
    if Features.oneof?(field) do
      case msg.oneofs[field.oneof_index] do
        nil ->
          acc

        oneof ->
          Enum.reduce(oneof.fields, acc, fn fname, acc ->
            if fname != field.name, do: Map.delete(acc, fname), else: acc
          end)
      end
    else
      acc
    end
  end

  # Map entries decode like Go's consumeMap: field 1 is the key, field 2 the
  # value, and anything else, including a key or value with the wrong wire
  # type, is skipped. A closed enum value that is not declared instead moves
  # the whole entry to the unknown fields, as in C++ (Go has no closed enums).
  # Missing keys and values default in finalization.
  defp decode_map_entry(_schema, _entry, _body, depth, _opts, path)
       when depth >= @max_decode_depth,
       do: decode_error_at({:malformed, :max_decode_depth_exceeded}, path)

  defp decode_map_entry(schema, entry, body, depth, opts, path),
    do: decode_map_entry_fields(schema, entry, body, %{}, depth + 1, opts, path)

  defp decode_map_entry_fields(_schema, _entry, <<>>, acc, _depth, _opts, _path), do: {:ok, acc}

  defp decode_map_entry_fields(schema, entry, bin, acc, depth, opts, path) do
    with {:ok, tag_val, rest} <- Wire.decode_tag(bin),
         fnum = tag_val >>> 3,
         wtype = tag_val &&& 0x07,
         :ok <- Wire.validate_field_number(fnum),
         :ok <- Wire.validate_wire_type(wtype) do
      case entry.fields_by_number[fnum] do
        %{wire_type: ^wtype} = field ->
          field_path = path ++ [field.name]

          with {:ok, _raw_body, raw, rest} <- read_field_value(field, wtype, rest),
               {:ok, value} <- interpret(schema, field, raw, depth, opts, field_path) do
            acc = store_decoded_value(schema, acc, entry, field, value, :field)
            decode_map_entry_fields(schema, entry, rest, acc, depth, opts, path)
          else
            {:error, {:closed_enum_value, _raw}} -> :closed_enum_value
            {:error, reason} -> decode_error_at(reason, field_path)
          end

        _other ->
          with {:ok, _raw, rest} <- Wire.read_unknown_field(fnum, wtype, rest) do
            decode_map_entry_fields(schema, entry, rest, acc, depth, opts, path)
          else
            {:error, reason} -> decode_error_at(reason, path)
          end
      end
    else
      {:error, reason} -> decode_error_at(reason, path)
    end
  end

  defp interpret(schema, field, raw, depth, opts, path) do
    case field.type do
      :TYPE_MESSAGE ->
        if depth >= @max_decode_depth do
          decode_error_at({:malformed, :max_decode_depth_exceeded}, path)
        else
          with {:ok, ref} <- RuntimeSchema.fetch_message(schema, field.type_name),
               {:ok, fields, <<>>} <- fields(schema, ref, raw, depth + 1, opts, path) do
            {:ok, fields}
          else
            {:error, reason} -> decode_error_at(reason, path)
          end
        end

      _scalar ->
        Scalar.decode(field, raw)
    end
  end

  defp decode_packed_values(field, data, path) do
    decode_packed_values(field, data, path, 0, [], [])
  end

  # `values` is accumulated by prepending (`[value | values]`), so it ends in
  # reverse-storage order — identical to the element-by-element repeated path,
  # which finalize reverses once. Returning it as-is (rather than reversing to
  # wire order only for the caller to reverse back) avoids a redundant O(n) copy
  # pair on the decode hot path. Unknowns are returned in wire order for the
  # caller's left-to-right `UnknownField.append` reduce.
  defp decode_packed_values(_field, <<>>, _path, _index, values, unknowns),
    do: {:ok, values, Enum.reverse(unknowns)}

  defp decode_packed_values(field, data, path, index, values, unknowns) do
    case read_packed_scalar(field, data) do
      {:ok, raw, rest} ->
        case Scalar.decode(field, raw) do
          {:ok, value} ->
            decode_packed_values(field, rest, path, index + 1, [value | values], unknowns)

          {:error, {:closed_enum_value, _raw}} ->
            unknown = UnknownField.from_raw(field.number, 0, Wire.encode_varint(raw))
            decode_packed_values(field, rest, path, index + 1, values, [unknown | unknowns])

          {:error, reason} ->
            decode_error_at(reason, path ++ [{:index, index}])
        end

      {:error, reason} ->
        decode_error_at(reason, path ++ [{:index, index}])
    end
  end

  defp read_packed_scalar(field, data) do
    case Wire.wire_type(field.type) do
      0 -> Wire.decode_varint(data)
      1 -> Wire.read_wire(1, data)
      5 -> Wire.read_wire(5, data)
      _ -> {:error, {:malformed, :unpackable_wire_type, %{type: field.type}}}
    end
  end

  defp decode_error_at(%{__exception__: true} = error, _path), do: {:error, error}

  defp decode_error_at(reason, path) do
    {:error, reason |> Errors.to_error(:decode) |> PB.Error.prepend_path(resolve_path(path))}
  end

  # Resolve any deferred `{:index_of, list}` markers (see decode_value_path) to
  # concrete `{:index, n}` elements. Runs only when an error is rendered.
  defp resolve_path(path) do
    Enum.map(path, fn
      {:index_of, list} -> {:index, length(list)}
      element -> element
    end)
  end
end

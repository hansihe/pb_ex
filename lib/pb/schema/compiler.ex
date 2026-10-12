defmodule PB.Schema.Compiler do
  @moduledoc false

  # Compiles decoded protobuf descriptors into PB's draft schema format.
  #
  # This module owns descriptor-to-schema semantics: field cardinality, field
  # presence, wire encoding, effective features, extensions, oneof membership, and
  # map lowering are resolved here. The result of `compile/1` is still a draft
  # schema, not something runtime encode/decode should consume directly.
  #
  # Descriptor options are kept, so annotators can compile validation rules and
  # projections from them and `PB.Schema.Info` can expose them. Draft schemas
  # intentionally do not contain runtime-only metadata such as numeric field
  # indexes, encoded tags, enum refs, adapter refs, required/default field
  # lists, or oneof lookup maps.
  # `PB.Schema.Prepare.prepare/1` is the only phase that writes those values.

  alias PB.Schema.Features
  alias PB.Schema.ExtensionMaterializer

  @doc """
  Returns a draft schema for a decoded `FileDescriptorSet`.

  The draft is semantically normalized enough for annotation passes to reason
  about field shape, including maps and extension options. It must remain free
  of prepared runtime metadata so later transforms can still change adapters or
  the reachable schema slice before the final preparation pass.
  """
  def compile(descriptor_set) do
    descriptor_set
    |> do_compile()
    |> ExtensionMaterializer.materialize()
  end

  defp do_compile(descriptor_set) do
    (descriptor_set[:file] || [])
    |> Enum.reduce(%{messages: %{}, enums: %{}, services: %{}, extensions_by_name: %{}}, fn file,
                                                                                            acc ->
      package = to_atom(file[:package])
      syntax = to_atom(file[:syntax]) || :proto2
      edition = to_atom(file[:edition])
      features = Features.file_context(syntax, edition, file[:options])
      source = Features.source(syntax, edition)

      acc = compile_messages(file[:message_type] || [], package, package, source, features, acc)
      acc = compile_enums(file[:enum_type] || [], package, package, features, acc)
      acc = compile_extensions(file[:extension] || [], package, source, features, acc)
      compile_services(file[:service] || [], package, acc)
    end)
    |> attach_extensions()
    |> resolve_map_fields()
  end

  defp compile_messages(messages, package, parent, source, features, acc) do
    Enum.reduce(messages, acc, fn msg, acc ->
      fqn = make_fqn(parent, to_atom(msg[:name]))
      message_features = Features.message_context(features, msg[:options])
      acc = compile_one_message(msg, fqn, package, source, message_features, acc)

      acc =
        compile_messages(msg[:nested_type] || [], package, fqn, source, message_features, acc)

      acc = compile_enums(msg[:enum_type] || [], package, fqn, message_features, acc)
      compile_extensions(msg[:extension] || [], fqn, source, message_features, acc)
    end)
  end

  defp compile_one_message(msg, fqn, package, source, features, acc) do
    fields = msg[:field] || []
    oneofs = compile_oneofs(msg[:oneof_decl] || [], fields)
    map_entry = get_in(msg, [:options, :map_entry]) == true

    infos = Enum.map(fields, &compile_field(&1, features, :field, nil))

    by_name = Map.new(infos, &{&1.name, &1})

    message_info =
      %{
        kind: :message,
        package: package,
        fields_by_name: by_name,
        oneofs: oneofs,
        map_entry: map_entry,
        extension_ranges: compile_extension_ranges(msg[:extension_range] || []),
        extensions_by_name: %{},
        syntax: source.syntax,
        edition: source.edition,
        source: source,
        reserved_names: Enum.map(msg[:reserved_name] || [], &to_string/1),
        reserved_ranges:
          Enum.map(msg[:reserved_range] || [], &%{start: &1[:start], end: &1[:end]}),
        features: features
      }
      |> maybe_put(:options, msg[:options])

    put_in(acc, [:messages, fqn], message_info)
  end

  defp compile_oneofs(decls, fields) do
    decls
    |> Enum.with_index()
    |> Enum.map(fn {decl, idx} ->
      members =
        fields
        |> Enum.filter(&(&1[:oneof_index] == idx and !&1[:proto3_optional]))
        |> Enum.map(&to_atom(&1[:name]))

      oneof_info =
        %{name: to_atom(decl[:name]), fields: members}
        |> maybe_put(:options, decl[:options])

      {idx, oneof_info}
    end)
    |> Enum.reject(fn {_idx, o} -> o.fields == [] end)
    |> Map.new()
  end

  defp compile_enums(enums, package, parent, features, acc) do
    Enum.reduce(enums, acc, fn e, acc ->
      fqn = make_fqn(parent, to_atom(e[:name]))
      vals = e[:value] || []
      by_name = Map.new(vals, &{to_atom(&1[:name]), &1[:number]})
      # Aliases share a number; like protoc, the first declared name wins.
      by_number = vals |> Enum.reverse() |> Map.new(&{&1[:number], to_atom(&1[:name])})
      enum_features = Features.enum_features(features, e[:options])

      put_in(acc, [:enums, fqn], %{
        package: package,
        by_name: by_name,
        by_number: by_number,
        default: enum_default(vals),
        features: enum_features
      })
    end)
  end

  # An enum field without an explicit default defaults to the first declared
  # value, which is 0 in open enums but may be any number in closed ones.
  defp enum_default([first | _]), do: to_atom(first[:name])
  defp enum_default([]), do: 0

  defp compile_services(services, package, acc) do
    Enum.reduce(services, acc, fn svc, acc ->
      fqn = make_fqn(package, to_atom(svc[:name]))

      methods =
        Map.new(svc[:method] || [], fn m ->
          {to_atom(m[:name]),
           %{
             input_type: resolve_type_name(m[:input_type]),
             output_type: resolve_type_name(m[:output_type]),
             client_streaming: m[:client_streaming] == true,
             server_streaming: m[:server_streaming] == true
           }}
        end)

      put_in(acc, [:services, fqn], %{package: package, methods: methods})
    end)
  end

  defp compile_extensions(extensions, parent, _source, features, acc) do
    Enum.reduce(extensions, acc, fn extension, acc ->
      extendee = resolve_type_name(extension[:extendee])
      field = compile_field(extension, features, :extension, parent)

      field =
        field
        |> Map.put(:kind, :extension)
        |> Map.put(:extendee, extendee)

      put_in(acc, [:extensions_by_name, field.name], field)
    end)
  end

  defp compile_field(field, features, kind, parent) do
    semantics = Features.field_semantics(features, field)
    type = Features.runtime_type(field[:type])
    wt = Features.wire_type(type, semantics.encoding)
    local_name = to_atom(field[:name])

    name =
      case kind do
        :extension -> make_fqn(parent, local_name)
        :field -> local_name
      end

    info = %{
      name: name,
      number: field[:number],
      type: type,
      wire_type: wt,
      cardinality: semantics.cardinality,
      presence: semantics.presence,
      encoding: semantics.encoding,
      features: semantics.features,
      source: semantics.source
    }

    info =
      case kind do
        :extension -> Map.put(info, :local_name, local_name)
        :field -> info
      end

    info =
      if field[:type_name],
        do: Map.put(info, :type_name, resolve_type_name(field[:type_name])),
        else: info

    info = maybe_put_default_value(info, field)
    info = if field[:json_name], do: Map.put(info, :json_name, field[:json_name]), else: info
    info = maybe_put(info, :options, field[:options])

    if semantics.presence == :oneof,
      do: Map.put(info, :oneof_index, field[:oneof_index]),
      else: info
  end

  defp compile_extension_ranges(ranges) do
    Enum.map(ranges, fn range ->
      %{
        start: range[:start],
        end: range[:end]
      }
      |> maybe_put(:options, range[:options])
    end)
  end

  defp attach_extensions(%{extensions_by_name: extensions} = acc) do
    Enum.reduce(extensions, acc, fn {_name, %{extendee: extendee} = extension}, acc ->
      if Map.has_key?(acc.messages, extendee) do
        acc
        |> put_in([:messages, extendee, :extensions_by_name, extension.name], extension)
      else
        acc
      end
    end)
  end

  # Map fields are a descriptor convention: a repeated message field whose
  # target message has `map_entry = true`. Lower that convention once here so
  # every later phase sees explicit `cardinality: :map` fields.
  defp resolve_map_fields(%{messages: messages, extensions_by_name: extensions_by_name} = schema) do
    messages =
      messages
      |> resolve_map_entry_value_fields()
      |> then(fn messages ->
        Map.new(messages, fn {fqn, message} ->
          {fqn, resolve_message_map_fields(message, messages)}
        end)
      end)

    extensions_by_name =
      Map.new(extensions_by_name, fn {name, field} ->
        {name, resolve_map_field(field, messages)}
      end)

    schema
    |> Map.put(:messages, messages)
    |> Map.put(:extensions_by_name, extensions_by_name)
  end

  defp resolve_map_entry_value_fields(messages) do
    Map.new(messages, fn {fqn, message} ->
      fields_by_name =
        if message.map_entry do
          update_in(message.fields_by_name, [:value], fn
            %{type: :TYPE_MESSAGE} = field ->
              field
              |> Map.put(:encoding, :length_prefixed)
              |> Map.put(:wire_type, 2)

            field ->
              field
          end)
        else
          message.fields_by_name
        end

      {fqn, Map.put(message, :fields_by_name, fields_by_name)}
    end)
  end

  defp resolve_message_map_fields(message, messages) do
    fields_by_name =
      Map.new(message.fields_by_name, fn {name, field} ->
        {name, resolve_map_field(field, messages)}
      end)

    extensions_by_name =
      Map.new(message.extensions_by_name, fn {name, field} ->
        {name, resolve_map_field(field, messages)}
      end)

    message
    |> Map.put(:fields_by_name, fields_by_name)
    |> Map.put(:extensions_by_name, extensions_by_name)
  end

  defp resolve_map_field(
         %{type: :TYPE_MESSAGE, cardinality: cardinality, type_name: type_name} = field,
         messages
       )
       when cardinality in [:repeated, :map] do
    case Map.fetch!(messages, type_name) do
      %{map_entry: true} = map_msg ->
        field
        |> Map.put(:cardinality, :map)
        |> Map.put(:encoding, :length_prefixed)
        |> Map.put(:wire_type, 2)
        |> Map.put(:map_entry, map_msg)
        |> Map.put(:map_key, map_msg.fields_by_name[:key])
        |> Map.put(:map_value, map_msg.fields_by_name[:value])

      %{kind: :message} ->
        field
        |> Map.delete(:map_entry)
        |> Map.delete(:map_key)
        |> Map.delete(:map_value)
    end
  end

  defp resolve_map_field(field, _messages), do: field

  defp make_fqn(nil, name), do: name
  defp make_fqn(parent, name), do: :"#{parent}.#{name}"

  defp to_atom(nil), do: nil
  defp to_atom(v) when is_atom(v), do: v
  defp to_atom(v) when is_binary(v), do: String.to_atom(v)

  defp maybe_put_default_value(info, %{default_value: value}) when is_binary(value) do
    Map.put(info, :default, parse_default_value(info.type, value))
  end

  defp maybe_put_default_value(info, _field), do: info

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_default_value(type, value) when type in [:TYPE_DOUBLE, :TYPE_FLOAT] do
    case String.downcase(value) do
      "nan" ->
        :nan

      "inf" ->
        :infinity

      "infinity" ->
        :infinity

      "-inf" ->
        :negative_infinity

      "-infinity" ->
        :negative_infinity

      _other ->
        case Float.parse(value) do
          {float, ""} -> float
          _other -> raise ArgumentError, "invalid protobuf floating default #{inspect(value)}"
        end
    end
  end

  defp parse_default_value(type, value)
       when type in [
              :TYPE_INT32,
              :TYPE_INT64,
              :TYPE_SINT32,
              :TYPE_SINT64,
              :TYPE_SFIXED32,
              :TYPE_SFIXED64
            ] do
    parse_integer_default(value)
  end

  defp parse_default_value(type, value)
       when type in [:TYPE_UINT32, :TYPE_UINT64, :TYPE_FIXED32, :TYPE_FIXED64] do
    parse_integer_default(value)
  end

  defp parse_default_value(:TYPE_BOOL, "true"), do: true
  defp parse_default_value(:TYPE_BOOL, "false"), do: false
  defp parse_default_value(:TYPE_STRING, value), do: value
  defp parse_default_value(:TYPE_BYTES, value), do: decode_bytes_default(value)
  defp parse_default_value(:TYPE_ENUM, value), do: to_atom(value)
  defp parse_default_value(_type, value), do: value

  defp parse_integer_default(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> raise ArgumentError, "invalid protobuf integer default #{inspect(value)}"
    end
  end

  defp decode_bytes_default(value) do
    value
    |> :erlang.binary_to_list()
    |> decode_bytes_chars([])
    |> :erlang.list_to_binary()
  end

  defp decode_bytes_chars([], acc), do: Enum.reverse(acc)

  defp decode_bytes_chars([?\\, ?n | rest], acc), do: decode_bytes_chars(rest, [?\n | acc])
  defp decode_bytes_chars([?\\, ?r | rest], acc), do: decode_bytes_chars(rest, [?\r | acc])
  defp decode_bytes_chars([?\\, ?t | rest], acc), do: decode_bytes_chars(rest, [?\t | acc])
  defp decode_bytes_chars([?\\, ?\\ | rest], acc), do: decode_bytes_chars(rest, [?\\ | acc])
  defp decode_bytes_chars([?\\, ?" | rest], acc), do: decode_bytes_chars(rest, [?" | acc])
  defp decode_bytes_chars([?\\, ?' | rest], acc), do: decode_bytes_chars(rest, [?' | acc])

  defp decode_bytes_chars([?\\, digit | rest], acc) when digit in ?0..?7 do
    {digits, rest} = take_octal_digits(rest, [digit], 2)
    {byte, ""} = digits |> Enum.reverse() |> :erlang.list_to_binary() |> Integer.parse(8)
    decode_bytes_chars(rest, [byte | acc])
  end

  defp decode_bytes_chars([char | rest], acc), do: decode_bytes_chars(rest, [char | acc])

  defp take_octal_digits(rest, digits, 0), do: {digits, rest}

  defp take_octal_digits([digit | rest], digits, remaining) when digit in ?0..?7 do
    take_octal_digits(rest, [digit | digits], remaining - 1)
  end

  defp take_octal_digits(rest, digits, _remaining), do: {digits, rest}

  defp resolve_type_name(nil), do: nil
  defp resolve_type_name(v) when is_atom(v), do: v

  defp resolve_type_name(v) when is_binary(v),
    do: v |> String.trim_leading(".") |> String.to_atom()
end

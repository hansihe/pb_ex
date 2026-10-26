defmodule PB.TestSupport.CodegenConsistency do
  @moduledoc false

  import ExUnit.Assertions

  @prepare_opts [:projections, :roots, :module]
  @encode_opts [:encode_opts]
  @roundtrip_opts [:encode_opts]
  @schema_roundtrip_opts @prepare_opts ++ @roundtrip_opts

  def prepare_codec(schema, root, opts \\ [])
      when is_map(schema) and is_atom(root) and is_list(opts) do
    validate_opts!(opts, @prepare_opts, :prepare_codec)

    schema
    |> prepare_schema(root, opts)
    |> build_generated_codec(
      root,
      Keyword.get_lazy(opts, :module, fn -> unique_module(root) end),
      [:encoder, :decoder]
    )
  end

  def prepare_encoder(schema, root, opts \\ [])
      when is_map(schema) and is_atom(root) and is_list(opts) do
    validate_opts!(opts, @prepare_opts, :prepare_encoder)

    schema
    |> prepare_schema(root, opts)
    |> build_generated_codec(
      root,
      Keyword.get_lazy(opts, :module, fn -> unique_module(root) end),
      :encoder
    )
  end

  def prepare_decoder(schema, root, opts \\ [])
      when is_map(schema) and is_atom(root) and is_list(opts) do
    validate_opts!(opts, @prepare_opts, :prepare_decoder)

    schema
    |> prepare_schema(root, opts)
    |> build_generated_codec(
      root,
      Keyword.get_lazy(opts, :module, fn -> unique_module(root) end),
      :decoder
    )
  end

  def assert_encode_consistent(codec, value) when is_map(codec) do
    assert_encode_consistent(codec, value, [])
  end

  def assert_encode_consistent(codec, value, opts) when is_map(codec) and is_list(opts) do
    validate_opts!(opts, @encode_opts, :assert_encode_consistent)

    encode_opts = Keyword.get(opts, :encode_opts, [])
    dynamic = PB.encode(value, codec.schema, codec.root, encode_opts)
    generated = apply(codec.module, codec.encode, [value, encode_opts])

    assert_encode_results_equal(generated, dynamic)
    dynamic
  end

  def assert_encode_consistent(schema, root, value, opts \\ [])
      when is_map(schema) and is_atom(root) and is_list(opts) do
    validate_opts!(opts, @prepare_opts ++ @encode_opts, :assert_encode_consistent)

    schema
    |> prepare_encoder(root, Keyword.take(opts, @prepare_opts))
    |> assert_encode_consistent(value, Keyword.take(opts, @encode_opts))
  end

  def assert_decode_consistent(decoder, binary) when is_map(decoder) do
    dynamic = expected_generated_decode(decoder.schema, decoder.root, binary)
    generated = apply(decoder.module, decoder.decode, [binary])

    assert generated == dynamic
    dynamic
  end

  def assert_decode_consistent(schema, root, binary, opts \\ [])
      when is_map(schema) and is_atom(root) and is_list(opts) do
    schema
    |> prepare_decoder(root, opts)
    |> assert_decode_consistent(binary)
  end

  def assert_decode_roundtrip_consistent(decoder, value) when is_map(decoder) do
    assert_decode_roundtrip_consistent(decoder, value, [])
  end

  def assert_decode_roundtrip_consistent(decoder, value, opts)
      when is_map(decoder) and is_list(opts) do
    validate_opts!(opts, @roundtrip_opts, :assert_decode_roundtrip_consistent)

    encode_opts = Keyword.get(opts, :encode_opts, [])
    {:ok, iodata} = PB.encode(value, decoder.schema, decoder.root, encode_opts)
    binary = IO.iodata_to_binary(iodata)

    assert_decode_consistent(decoder, binary)
  end

  def assert_decode_roundtrip_consistent(schema, root, value)
      when is_map(schema) and is_atom(root) do
    assert_decode_roundtrip_consistent(schema, root, value, [])
  end

  def assert_decode_roundtrip_consistent(schema, root, value, opts)
      when is_map(schema) and is_atom(root) and is_list(opts) do
    validate_opts!(opts, @schema_roundtrip_opts, :assert_decode_roundtrip_consistent)

    decoder = prepare_decoder(schema, root, Keyword.take(opts, @prepare_opts))
    assert_decode_roundtrip_consistent(decoder, value, Keyword.take(opts, @roundtrip_opts))
  end

  def assert_codec_roundtrip_consistent(codec, value) when is_map(codec) do
    assert_codec_roundtrip_consistent(codec, value, [])
  end

  def assert_codec_roundtrip_consistent(codec, value, opts)
      when is_map(codec) and is_list(opts) do
    validate_opts!(opts, @encode_opts, :assert_codec_roundtrip_consistent)

    encode_opts = Keyword.get(opts, :encode_opts, [])
    {:ok, generated_iodata} = assert_encode_consistent(codec, value, encode_opts: encode_opts)
    binary = IO.iodata_to_binary(generated_iodata)

    assert_decode_consistent(codec, binary)
  end

  defp build_generated_codec(prepared, root, module, emit) do
    ctx = PB.Codegen.build(prepared)
    name = Map.fetch!(ctx.names, root)

    ast = PB.Codegen.module(module, prepared, emit: emit)
    compile_module!(ast, module)

    %{
      schema: prepared,
      module: module,
      root: root,
      name: name,
      encode: :"encode_#{name}",
      encode!: :"encode_#{name}!",
      decode: :"decode_#{name}",
      decode!: :"decode_#{name}!"
    }
  end

  defp prepare_schema(schema, root, opts) do
    projections = Keyword.get(opts, :projections, [])
    roots = Keyword.get(opts, :roots, [root])

    schema
    |> maybe_projections(projections)
    |> PB.Schema.Transform.slice(roots: roots)
  end

  defp maybe_projections(schema, []), do: schema

  defp maybe_projections(schema, projections),
    do: PB.Schema.Transform.projections(schema, projections)

  defp compile_module!(ast, module) do
    case Code.compile_quoted(ast) do
      [{^module, _binary}] ->
        module

      other ->
        raise "expected Code.compile_quoted/1 to define #{inspect(module)}, got: #{inspect(other)}"
    end
  end

  defp unique_module(root) do
    suffix =
      root
      |> Atom.to_string()
      |> String.replace(~r/[^A-Za-z0-9]/, "_")

    unique = System.unique_integer([:positive, :monotonic])
    Module.concat([PB, TestSupport, CodegenConsistency, "Generated#{suffix}#{unique}"])
  end

  defp validate_opts!(opts, allowed, caller) do
    unknown = Keyword.keys(opts) -- allowed

    if unknown != [] do
      raise ArgumentError,
            "unknown PB.TestSupport.CodegenConsistency.#{caller} option(s): #{inspect(unknown)}"
    end
  end

  defp assert_encode_results_equal({:ok, generated}, {:ok, dynamic}) do
    assert IO.iodata_to_binary(generated) == IO.iodata_to_binary(dynamic)
  end

  defp assert_encode_results_equal(generated, dynamic) do
    assert generated == dynamic
  end

  defp expected_generated_decode(schema, root, binary) do
    case PB.decode(binary, schema, root) do
      {:ok, decoded} ->
        msg = Map.fetch!(schema.messages, root)
        {:ok, apply_generated_defaults(schema, msg, decoded)}

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_generated_defaults(schema, msg, decoded) when is_map(decoded) do
    decoded
    |> default_present_values(schema, msg)
    |> default_missing_values(schema, msg)
  end

  defp apply_generated_defaults(_schema, _msg, decoded), do: decoded

  defp default_present_values(decoded, schema, msg) do
    decoded
    |> Enum.reduce(decoded, fn {name, value}, acc ->
      cond do
        field = msg.fields_by_name[name] ->
          Map.put(acc, name, default_present_value(schema, field, value))

        oneof = find_oneof(msg.oneofs, name) ->
          Map.put(acc, name, default_oneof_value(schema, msg, oneof, value))

        true ->
          acc
      end
    end)
  end

  defp default_present_value(schema, field, value) do
    cond do
      map_field?(schema, field) ->
        default_present_map_values(schema, field, value)

      field.cardinality == :repeated and field.type == :TYPE_MESSAGE ->
        Enum.map(value, &default_present_message_value(schema, field, &1))

      field.type == :TYPE_MESSAGE ->
        default_present_message_value(schema, field, value)

      true ->
        value
    end
  end

  defp default_present_map_values(schema, field, value) when is_map(value) do
    map_msg = map_entry_message(schema, field)
    value_field = map_msg.fields_by_name[:value]

    if value_field.type == :TYPE_MESSAGE and value_field[:adapter] == nil do
      Map.new(value, fn {key, map_value} ->
        {key, default_present_message_value(schema, value_field, map_value)}
      end)
    else
      value
    end
  end

  defp default_present_map_values(_schema, _field, value), do: value

  defp default_present_message_value(schema, field, value) when is_map(value) do
    case field[:adapter] do
      nil ->
        msg = Map.fetch!(schema.messages, field.type_name)
        apply_generated_defaults(schema, msg, value)

      _custom ->
        value
    end
  end

  defp default_present_message_value(_schema, _field, value), do: value

  defp default_oneof_value(schema, msg, oneof, {field_name, value}) do
    field = Map.fetch!(msg.fields_by_name, field_name)

    if field_name in oneof.fields do
      {field_name, default_present_value(schema, field, value)}
    else
      {field_name, value}
    end
  end

  defp default_oneof_value(_schema, _msg, _oneof, value), do: value

  defp default_missing_values(decoded, schema, msg) do
    Enum.reduce(msg.fields_by_name, decoded, fn {name, field}, acc ->
      cond do
        Map.has_key?(acc, name) ->
          acc

        PB.Runtime.Scalar.has_presence?(field) ->
          acc

        map_field?(schema, field) ->
          Map.put(acc, name, %{})

        field.cardinality == :repeated ->
          Map.put(acc, name, [])

        true ->
          {:ok, default} = PB.Runtime.Scalar.default_value(field)
          Map.put(acc, name, default)
      end
    end)
  end

  defp map_field?(_schema, field), do: field.cardinality == :map

  defp map_entry_message(_schema, %{map_entry: %{map_entry: true} = map_msg}), do: map_msg

  defp find_oneof(oneofs, name) do
    Enum.find_value(oneofs, fn {_index, oneof} -> if oneof.name == name, do: oneof end)
  end
end

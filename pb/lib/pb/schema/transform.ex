defmodule PB.Schema.Transform do
  @moduledoc false

  # Schema transforms that run between draft compilation and preparation.
  #
  # The public functions in this module return prepared schemas because callers
  # use them with runtime encode/decode. The `slice_draft/2` function
  # deliberately returns a draft schema so `PB.compile/2` can compose all
  # transforms before the single final `PB.Schema.Prepare.prepare/1` pass.
  #
  # Transforms are strict schema edits. They reject unknown targets, duplicate
  # bindings, and map-entry targets instead of preserving fallback behavior. If
  # the schema shape is invalid, the caller should get a clear error before
  # runtime use.

  alias PB.Schema.ExtensionMaterializer
  alias PB.Schema.Prepare
  alias PB.Schema.Projections

  @doc """
  Applies projection entries and returns a prepared schema.
  """
  def projections(schema, projections) when is_map(schema) and is_list(projections) do
    schema
    |> Projections.apply(projections)
    |> Prepare.prepare()
  end

  @doc """
  Narrows a schema to root messages and returns a prepared schema.
  """
  def slice(schema, opts) when is_map(schema) and is_list(opts) do
    schema
    |> slice_draft(opts)
    |> Prepare.prepare()
  end

  @doc """
  Narrows a schema to root messages and returns a draft schema.

  The slice keeps the reachable closure of message, enum, and extension
  definitions needed by the selected roots. Extension traversal follows
  materialized descriptor options as well as field references so validation
  metadata remains self-contained.
  """
  def slice_draft(schema, opts) when is_map(schema) and is_list(opts) do
    roots = normalize_slice_roots(Keyword.fetch!(opts, :roots))

    state =
      Enum.reduce(roots, slice_state(), fn {fqn, _name}, state ->
        if Map.has_key?(schema.messages, fqn) do
          collect_message(schema, fqn, state)
        else
          raise ArgumentError, "unknown PB slice root #{inspect(fqn)}"
        end
      end)

    messages = Map.take(schema.messages, MapSet.to_list(state.messages))
    enums = Map.take(schema.enums, MapSet.to_list(state.enums))

    extensions =
      schema
      |> Map.fetch!(:extensions_by_name)
      |> Map.take(MapSet.to_list(state.extensions))
      |> Map.merge(extensions_from_messages(messages))

    root_fqns = Enum.map(roots, &elem(&1, 0))

    root_names =
      roots
      |> Enum.filter(fn {_fqn, name} -> name != nil end)
      |> Map.new()

    schema
    |> Map.put(:messages, messages)
    |> Map.put(:enums, enums)
    |> Map.put(:extensions_by_name, extensions)
    |> Map.put(:roots, root_fqns)
    |> Map.put(:root_names, root_names)
    |> Map.put(:services, %{})
  end

  defp normalize_slice_roots(roots) when is_list(roots) do
    Enum.map(roots, fn
      fqn when is_atom(fqn) ->
        {fqn, nil}

      {fqn, name} when is_atom(fqn) and is_atom(name) ->
        {fqn, name}

      {fqn, opts} when is_atom(fqn) and is_list(opts) ->
        name = Keyword.get(opts, :as)

        unless name == nil or is_atom(name) do
          raise ArgumentError,
                "invalid PB slice root name for #{inspect(fqn)}: #{inspect(name)}"
        end

        unknown = Keyword.keys(opts) -- [:as]

        if unknown != [] do
          raise ArgumentError, "unknown PB slice root option(s): #{inspect(unknown)}"
        end

        {fqn, name}

      root ->
        raise ArgumentError, "invalid PB slice root: #{inspect(root)}"
    end)
  end

  defp normalize_slice_roots(roots) do
    raise ArgumentError, "expected PB slice roots to be a list, got: #{inspect(roots)}"
  end

  defp slice_state do
    %{messages: MapSet.new(), enums: MapSet.new(), extensions: MapSet.new()}
  end

  defp collect_message(schema, fqn, state) do
    if MapSet.member?(state.messages, fqn) do
      state
    else
      msg = Map.fetch!(schema.messages, fqn)
      state = %{state | messages: MapSet.put(state.messages, fqn)}

      state =
        msg
        |> message_descriptor_values_for_slice()
        |> Enum.reduce(state, &collect_referenced_extensions(schema, &1, &2))

      msg
      |> message_fields_for_slice()
      |> Map.values()
      |> Enum.reduce(state, &collect_field(schema, &1, &2))
    end
  end

  defp collect_field(schema, %{type: :TYPE_ENUM, type_name: type_name}, state) do
    _enum = fetch_type!(schema.enums, type_name, :unknown_enum)
    %{state | enums: MapSet.put(state.enums, type_name)}
  end

  defp collect_field(schema, %{type: :TYPE_MESSAGE, type_name: type_name}, state) do
    case fetch_type!(schema.messages, type_name, :unknown_message) do
      %{map_entry: true} = map_msg ->
        state = collect_message(schema, type_name, state)
        state = collect_field(schema, map_msg.fields_by_name[:key], state)
        collect_field(schema, map_msg.fields_by_name[:value], state)

      %{kind: :message} ->
        collect_message(schema, type_name, state)
    end
  end

  defp collect_field(_schema, _field, state), do: state

  # A missing referenced type usually means the schema was compiled without
  # `--include_imports`. Surface a diagnosable PB.SchemaError instead of the raw
  # KeyError that Map.fetch!/2 would raise mid-slice.
  defp fetch_type!(types, type_name, kind) do
    case Map.fetch(types, type_name) do
      {:ok, type} -> type
      :error -> raise PB.SchemaError, kind: kind, name: type_name, type_name: type_name
    end
  end

  defp collect_referenced_extensions(schema, value, state) do
    value
    |> ExtensionMaterializer.referenced_extension_names()
    |> Enum.reduce(state, &collect_extension(schema, &1, &2))
  end

  defp collect_extension(schema, name, state) do
    if MapSet.member?(state.extensions, name) do
      state
    else
      extension = Map.fetch!(schema.extensions_by_name, name)
      state = %{state | extensions: MapSet.put(state.extensions, name)}

      state =
        extension
        |> descriptor_options_for_slice()
        |> Enum.reduce(state, &collect_referenced_extensions(schema, &1, &2))

      collect_field(schema, extension, state)
    end
  end

  defp message_descriptor_values_for_slice(msg) do
    descriptor_options_for_slice(msg) ++
      (msg.fields_by_name |> Map.values() |> Enum.flat_map(&descriptor_options_for_slice/1)) ++
      (msg
       |> Map.fetch!(:extensions_by_name)
       |> Map.values()
       |> Enum.flat_map(&descriptor_options_for_slice/1)) ++
      (msg
       |> Map.fetch!(:oneofs)
       |> Map.values()
       |> Enum.flat_map(&descriptor_options_for_slice/1)) ++
      (msg.extension_ranges |> Enum.flat_map(&descriptor_options_for_slice/1))
  end

  defp descriptor_options_for_slice(%{options: options}) when is_map(options), do: [options]
  defp descriptor_options_for_slice(_entry), do: []

  defp message_fields_for_slice(msg) do
    Map.merge(msg.fields_by_name, msg.extensions_by_name)
  end

  defp extensions_from_messages(messages) do
    messages
    |> Enum.flat_map(fn {_fqn, msg} -> msg.extensions_by_name end)
    |> Map.new()
  end
end

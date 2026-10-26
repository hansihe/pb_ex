defmodule PB.Codegen do
  @moduledoc """
  Reference code generation API used by tests and benchmarks.

  This module intentionally lives under `test/support`: runtime schema-map
  encode/decode is the production path, while this implementation remains as a
  benchmark target and reference implementation for comparing behaviour.

  Codegen consumes a prepared schema. Shape the schema with `PB.Schema.Transform.slice/2`;
  then pass the resulting schema to `generate/2`. Sliced root metadata decides
  which generated functions are public.

  For provider-backed generated modules, use this module directly:

      defmodule MyApp.Proto.Orders do
        use PB.Codegen,
          schema: MyApp.Proto.Schema,
          roots: [:"myapp.orders.Order"]
      end

  The convenience macro composes the same base operations as the dynamic path:

      schema_module.schema()
      |> PB.Schema.Transform.slice(roots: roots)
      |> PB.Codegen.generate()

  The current emitters are `:typespecs`, `:encoder`, and `:decoder`.

  ## Shape

      %{
        schema:    PB.schema(),
        roots:     [fqn],
        registry:  %{fqn => type_def},          # inline messages only
        names:     %{fqn => name_atom}          # inline names
      }

  If a schema has no `:roots` metadata, all inline non-map-entry messages in the
  schema are treated as public roots. Use `PB.Schema.Transform.slice/2` to control public
  roots and generated closure explicitly.
  """

  @default_emitters [:typespecs, :encoder, :decoder]
  @available_emitters [:typespecs, :encoder, :decoder]

  @type fqn :: atom
  @type name :: atom
  @type emitter :: :typespecs | :encoder | :decoder

  @type context :: %{
          schema: PB.schema(),
          roots: [fqn],
          registry: %{fqn => PB.Codegen.Typespec.type_def()},
          names: %{fqn => name}
        }

  @doc """
  Generates quoted declarations from a prepared schema.

  The schema should already be shaped with adapters and `PB.Schema.Transform.slice/2`. By
  default this emits type declarations, encoders, and decoders.

  ## Options

    * `:emit` - emitter or list of emitters. Supported emitters are
      `:typespecs`, `:encoder`, and `:decoder`.
  """
  @spec generate(PB.schema(), keyword) :: [Macro.t()]
  def generate(schema, opts \\ []) when is_map(schema) and is_list(opts) do
    validate_generate_opts!(opts)

    schema
    |> build()
    |> emit(Keyword.get(opts, :emit, @default_emitters))
  end

  @doc """
  Emits quoted declarations from a codegen context.
  """
  @spec emit(context, emitter | [emitter]) :: [Macro.t()]
  def emit(ctx, emitters \\ @default_emitters) when is_map(ctx) do
    emitters
    |> normalize_emitters!()
    |> Enum.flat_map(&emit_declarations(ctx, &1))
  end

  @doc """
  Returns quoted AST for a generated module.

  This helper is useful in tests and custom compile-time flows. The module body
  includes schema-slice metadata plus the selected generated declarations.
  """
  @spec module(module, PB.schema(), keyword) :: Macro.t()
  def module(module, schema, opts \\ [])
      when is_atom(module) and is_map(schema) and is_list(opts) do
    body = module_body(schema, opts)

    quote do
      defmodule unquote(module) do
        (unquote_splicing(body))
      end
    end
  end

  @doc """
  Returns the quoted declarations used inside a generated module body.
  """
  @spec module_body(PB.schema(), keyword) :: [Macro.t()]
  def module_body(schema, opts \\ []) when is_map(schema) and is_list(opts) do
    module_metadata(schema) ++ generate(schema, opts)
  end

  @doc """
  Generates codecs from a schema provider module.

  Required options:

    * `:schema` - module exposing `schema/0` or `__pb_schema__/0`.
    * `:roots` - roots passed to `PB.Schema.Transform.slice/2`.

  Optional options:

    * `:emit` - emitter or list of emitters. Defaults to
      `[:typespecs, :encoder, :decoder]`.
  """
  defmacro __using__(opts) do
    opts = eval_use_opts!(opts, __CALLER__)

    schema =
      opts.schema
      |> provider_schema!()
      |> PB.Schema.Transform.slice(roots: opts.roots)

    body = module_body(schema, emit: opts.emit)

    quote do
      (unquote_splicing(body))
    end
  end

  @doc """
  Build a codegen context from a prepared schema.
  """
  @spec build(PB.schema()) :: context
  def build(schema) do
    roots = schema_roots(schema)
    validate_roots!(schema, roots)

    registry =
      Enum.reduce(schema.messages, %{}, fn {fqn, msg}, registry ->
        if inline_message?(msg) and not Map.get(msg, :map_entry, false) do
          register_message(registry, schema, fqn)
        else
          registry
        end
      end)

    names = assign_names(registry, Map.get(schema, :root_names, %{}))

    %{
      schema: schema,
      roots: roots,
      registry: registry,
      names: names
    }
  end

  # ── Generated module API ────────────────────────────────────────────

  defp module_metadata(schema) do
    escaped_schema = Macro.escape(schema)
    roots = Map.get(schema, :roots, [])
    root_names = Map.get(schema, :root_names, %{})

    quote do
      @doc false
      @spec __pb_schema_slice__() :: PB.schema()
      def __pb_schema_slice__, do: unquote(escaped_schema)

      @doc false
      @spec __pb_roots__() :: [atom]
      def __pb_roots__, do: unquote(Macro.escape(roots))

      @doc false
      @spec __pb_root_names__() :: %{atom => atom}
      def __pb_root_names__, do: unquote(Macro.escape(root_names))
    end
    |> extract_clauses()
  end

  defp extract_clauses({:__block__, _meta, clauses}), do: clauses
  defp extract_clauses(clause), do: [clause]

  # ── Emitter dispatch ────────────────────────────────────────────────

  defp normalize_emitters!(emitter) when is_atom(emitter), do: normalize_emitters!([emitter])

  defp normalize_emitters!(emitters) when is_list(emitters) do
    Enum.reduce(emitters, [], fn
      emitter, acc when emitter in @available_emitters ->
        if emitter in acc, do: acc, else: acc ++ [emitter]

      emitter, _acc ->
        raise ArgumentError, "unknown PB codegen emitter #{inspect(emitter)}"
    end)
  end

  defp normalize_emitters!(emitters) do
    raise ArgumentError,
          "expected PB codegen emitters to be an atom or list, got: #{inspect(emitters)}"
  end

  defp validate_generate_opts!(opts) do
    unknown = Keyword.keys(opts) -- [:emit]

    if unknown != [] do
      raise ArgumentError, "unknown PB.Codegen.generate option(s): #{inspect(unknown)}"
    end
  end

  defp emit_declarations(ctx, :typespecs), do: emit_type_declarations(ctx)
  defp emit_declarations(ctx, :encoder), do: PB.Codegen.Encoder.emit_all(ctx)
  defp emit_declarations(ctx, :decoder), do: PB.Codegen.Decoder.emit_all(ctx)

  defp emit_type_declarations(ctx) do
    # TODO(codegen): Typespecs are rendered as strings and parsed back to AST.
    # Keep strings as a debug/doc view, but emit quoted type AST directly from
    # the structured type registry.
    ctx
    |> PB.Codegen.Typespec.render_types()
    |> Enum.map(fn {name, body} ->
      type_name = {name, [], Elixir}
      type_body = Code.string_to_quoted!(body)

      quote do
        @type unquote(type_name) :: unquote(type_body)
      end
    end)
  end

  # ── Convenience macro setup ─────────────────────────────────────────

  defp eval_use_opts!(opts_ast, caller) do
    {opts, _env} = Code.eval_quoted(opts_ast, [], caller)

    unless Keyword.keyword?(opts) do
      raise ArgumentError, "expected PB.Codegen options to be a keyword list"
    end

    unknown = Keyword.keys(opts) -- [:schema, :roots, :emit]

    if unknown != [] do
      raise ArgumentError, "unknown PB.Codegen option(s): #{inspect(unknown)}"
    end

    schema = fetch_required_opt!(opts, :schema)
    roots = fetch_required_opt!(opts, :roots)
    emitters = Keyword.get(opts, :emit, @default_emitters)

    unless is_atom(schema) and schema != nil do
      raise ArgumentError,
            "expected PB.Codegen :schema to be a module, got: #{inspect(schema)}"
    end

    %{schema: schema, roots: roots, emit: emitters}
  end

  defp fetch_required_opt!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError, "missing required PB.Codegen option #{inspect(key)}"
    end
  end

  defp provider_schema!(module) do
    Code.ensure_compiled!(module)

    cond do
      function_exported?(module, :schema, 0) ->
        module.schema()

      function_exported?(module, :__pb_schema__, 0) ->
        module.__pb_schema__()

      true ->
        raise ArgumentError,
              "PB.Codegen schema provider #{inspect(module)} must expose schema/0 or __pb_schema__/0"
    end
  end

  # ── Root handling ───────────────────────────────────────────────────

  defp schema_roots(schema) do
    if Map.has_key?(schema, :roots) do
      schema.roots
    else
      schema.messages
      |> Enum.filter(fn {_fqn, msg} ->
        inline_message?(msg) and not Map.get(msg, :map_entry, false)
      end)
      |> Enum.map(fn {fqn, _msg} -> fqn end)
      |> Enum.sort()
    end
  end

  defp validate_roots!(schema, roots) do
    Enum.each(roots, fn fqn ->
      case Map.get(schema.messages, fqn) do
        nil ->
          raise ArgumentError, "unknown PB codegen root #{inspect(fqn)}"

        %{map_entry: true} ->
          raise ArgumentError, "cannot use map-entry message #{inspect(fqn)} as a codegen root"

        msg when is_map(msg) ->
          :ok
      end
    end)
  end

  # ── Registry building ────────────────────────────────────────────────

  defp inline_message?(%{kind: :message}), do: true
  defp inline_message?(%{fields_by_name: _fields_by_name}), do: true
  defp inline_message?(_msg), do: false

  defp register_message(registry, schema, fqn) do
    if Map.has_key?(registry, fqn) do
      registry
    else
      do_register_message(registry, schema, fqn)
    end
  end

  defp do_register_message(registry, schema, fqn) do
    case schema.messages[fqn] do
      nil ->
        Map.put(registry, fqn, %{kind: :scalar, spec: "map()"})

      %{map_entry: true} ->
        registry

      msg ->
        registry = Map.put(registry, fqn, :placeholder)
        {fields, registry} = message_fields(registry, schema, msg)

        {oneof_fields, registry} =
          msg.oneofs
          |> Enum.sort_by(fn {idx, _} -> idx end)
          |> Enum.reduce({[], registry}, fn {_idx, oneof}, {acc, registry} ->
            {variants, registry} =
              Enum.reduce(oneof.fields, {[], registry}, fn fname, {vacc, registry} ->
                info = msg.fields_by_name[fname]
                registry = maybe_register_referenced(registry, schema, info)
                {vacc ++ [{fname, field_type_def(schema, info)}], registry}
              end)

            field = {oneof.name, %{type: %{kind: :oneof, variants: variants}, required: false}}
            {acc ++ [field], registry}
          end)

        Map.put(registry, fqn, %{kind: :map, fields: fields ++ oneof_fields})
    end
  end

  defp message_fields(registry, schema, msg) do
    msg.fields_by_name
    |> Enum.sort_by(fn {_name, info} -> info.number end)
    |> Enum.reject(fn {_name, info} -> PB.Schema.Features.oneof?(info) end)
    |> Enum.reduce({[], registry}, fn {name, info}, {fields, registry} ->
      type_def = field_type_def(schema, info)
      registry = maybe_register_referenced(registry, schema, info)
      required = PB.Schema.Features.required?(info)
      {fields ++ [{name, %{type: type_def, required: required}}], registry}
    end)
  end

  defp maybe_register_referenced(registry, schema, info) do
    cond do
      info.cardinality == :map ->
        map_msg = Map.fetch!(schema.messages, info.type_name)
        val_info = map_msg.fields_by_name[:value]

        if val_info && val_info.type == :TYPE_MESSAGE do
          register_message(registry, schema, val_info.type_name)
        else
          registry
        end

      info.type == :TYPE_MESSAGE ->
        register_message(registry, schema, info.type_name)

      true ->
        registry
    end
  end

  defp field_type_def(schema, info) do
    base =
      case info.type do
        :TYPE_STRING -> %{kind: :scalar, spec: "String.t()"}
        :TYPE_BYTES -> %{kind: :scalar, spec: "binary()"}
        :TYPE_BOOL -> %{kind: :scalar, spec: "boolean()"}
        :TYPE_DOUBLE -> %{kind: :scalar, spec: "float()"}
        :TYPE_FLOAT -> %{kind: :scalar, spec: "float()"}
        :TYPE_INT32 -> %{kind: :scalar, spec: "integer()"}
        :TYPE_INT64 -> %{kind: :scalar, spec: "integer()"}
        :TYPE_SINT32 -> %{kind: :scalar, spec: "integer()"}
        :TYPE_SINT64 -> %{kind: :scalar, spec: "integer()"}
        :TYPE_SFIXED32 -> %{kind: :scalar, spec: "integer()"}
        :TYPE_SFIXED64 -> %{kind: :scalar, spec: "integer()"}
        :TYPE_UINT32 -> %{kind: :scalar, spec: "non_neg_integer()"}
        :TYPE_UINT64 -> %{kind: :scalar, spec: "non_neg_integer()"}
        :TYPE_FIXED32 -> %{kind: :scalar, spec: "non_neg_integer()"}
        :TYPE_FIXED64 -> %{kind: :scalar, spec: "non_neg_integer()"}
        :TYPE_ENUM -> enum_type_def(schema, info[:type_name])
        :TYPE_MESSAGE -> message_ref(schema, info.type_name)
      end

    cond do
      info.cardinality == :map ->
        map_msg = Map.fetch!(schema.messages, info.type_name)
        key_info = map_msg.fields_by_name[:key]
        val_info = map_msg.fields_by_name[:value]

        %{
          kind: :map_of,
          key: field_type_def(schema, key_info),
          value: field_type_def(schema, val_info)
        }

      info.cardinality == :repeated ->
        %{kind: :list, inner: base}

      true ->
        base
    end
  end

  defp message_ref(schema, type_name) do
    case schema.messages[type_name] do
      %{projection: %{adapter: adapter}} when not is_nil(adapter) -> adapter_type_def(adapter)
      %{map_entry: true} -> %{kind: :scalar, spec: "map()"}
      _ -> %{kind: :ref, id: type_name}
    end
  end

  defp adapter_type_def(%{type: type}), do: %{kind: :scalar, spec: type_spec(type)}
  defp adapter_type_def(_adapter), do: %{kind: :scalar, spec: "term()"}

  defp type_spec(type) when is_binary(type), do: type
  defp type_spec(type) when is_atom(type), do: "#{type}()"

  defp type_spec(type) do
    Macro.to_string(type)
  rescue
    _ -> "term()"
  end

  defp enum_type_def(schema, type_name) do
    case schema.enums[type_name] do
      nil -> %{kind: :scalar, spec: "atom()"}
      enum -> %{kind: :enum, values: enum.by_name |> Map.keys() |> Enum.sort()}
    end
  end

  # ── Name assignment ─────────────────────────────────────────────────

  @noise_segments ~w(Request Response v1 v2 v3 rpc)
  @reserved_type_names MapSet.new(~w(
    any arity as_boolean atom binary bitstring boolean byte char charlist
    dynamic fun function identifier integer iodata iolist keyword list
    maybe_improper_list mfa module neg_integer nil no_return node none
    non_neg_integer number pid port pos_integer reference struct term
    timeout tuple
  ))

  defp assign_names(registry, overrides) do
    auto_ids = registry |> Map.keys() |> Enum.reject(&Map.has_key?(overrides, &1))

    suffixes_per_id =
      Map.new(auto_ids, fn id ->
        segments =
          id
          |> Atom.to_string()
          |> String.split(".")
          |> Enum.reject(&(&1 in @noise_segments))

        suffixes =
          for len <- 1..length(segments) do
            segments |> Enum.take(-len) |> Enum.join(".")
          end

        {id, suffixes}
      end)

    auto = assign_unique_names(auto_ids, suffixes_per_id, %{}, 0)
    Map.merge(auto, overrides)
  end

  defp assign_unique_names([], _suffixes, assignments, _level), do: assignments

  defp assign_unique_names(remaining, suffixes_per_id, assignments, level) do
    all_exhausted =
      Enum.all?(remaining, fn id ->
        Enum.at(suffixes_per_id[id], level) == nil
      end)

    if all_exhausted do
      remaining
      |> Enum.sort()
      |> Enum.with_index()
      |> Enum.reduce(assignments, fn {id, idx}, acc ->
        base = id |> Atom.to_string() |> Macro.underscore() |> String.replace("/", "_")
        name = if idx == 0, do: base, else: "#{base}_#{idx}"
        Map.put(acc, id, String.to_atom(name))
      end)
    else
      candidates =
        Map.new(remaining, fn id ->
          suffix = Enum.at(suffixes_per_id[id], level)
          {id, candidate_name(suffix)}
        end)

      suffix_counts =
        candidates
        |> Map.values()
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies()

      {assigned, still_remaining} =
        Enum.split_with(remaining, fn id ->
          candidate = candidates[id]
          candidate != nil and suffix_counts[candidate] == 1
        end)

      new_assignments =
        Enum.reduce(assigned, assignments, fn id, acc ->
          Map.put(acc, id, candidates[id])
        end)

      if still_remaining == [] do
        new_assignments
      else
        assign_unique_names(still_remaining, suffixes_per_id, new_assignments, level + 1)
      end
    end
  end

  defp candidate_name(nil), do: nil

  defp candidate_name(suffix) do
    name = suffix |> Macro.underscore() |> String.replace("/", "_")

    if MapSet.member?(@reserved_type_names, name) do
      nil
    else
      String.to_atom(name)
    end
  end
end

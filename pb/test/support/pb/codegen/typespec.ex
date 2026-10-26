defmodule PB.Codegen.Typespec do
  @moduledoc """
  Render typespecs from a `PB.Codegen` context.

  ## Example

      schema = PB.compile(descriptor_set)
      ctx =
        schema
        |> PB.Schema.Transform.slice(roots: [:"pkg.Order"])
        |> PB.Codegen.build()

      PB.Codegen.Typespec.to_string(ctx, :"pkg.Order")
      # => "%{optional(:id) => integer(), ...}"

      PB.Codegen.Typespec.render_types(ctx)
      # => [{:order, "%{optional(:id) => integer(), ...}"}, ...]

  References to adapted message leaves render using the declared `:type` when
  present, or `term()` otherwise.
  """

  @typedoc "Structured type definition used by the registry."
  @type type_def ::
          %{kind: :scalar, spec: String.t()}
          | %{kind: :map, fields: [{atom, %{type: type_def, required: boolean}}]}
          | %{kind: :list, inner: type_def}
          | %{kind: :enum, values: [atom]}
          | %{kind: :ref, id: atom}
          | %{kind: :nullable, inner: type_def}
          | %{kind: :map_of, key: type_def, value: type_def}
          | %{kind: :oneof, variants: [{atom, type_def}]}
          | :placeholder

  @doc """
  Render a single registry entry from the context as an Elixir typespec string.
  """
  @spec to_string(PB.Codegen.context(), atom) :: String.t()
  def to_string(ctx, fqn) do
    type_def = Map.fetch!(ctx.registry, fqn)
    format_type_def(ctx, type_def, 0)
  end

  @doc """
  Render all inline registry entries as typespec body strings, topologically
  sorted so referenced types appear before the types that reference them.

  Returns `[{name_atom, body_string}]`.
  """
  @spec render_types(PB.Codegen.context()) :: [{atom, String.t()}]
  def render_types(ctx) do
    sorted = topo_sort(ctx.registry)

    Enum.map(sorted, fn fqn ->
      type_def = Map.fetch!(ctx.registry, fqn)
      name = Map.fetch!(ctx.names, fqn)
      body = format_type_def(ctx, type_def, 0)
      {name, body}
    end)
  end

  @doc """
  Return quoted Elixir AST for a single registry entry's type body.
  """
  @spec to_quoted(PB.Codegen.context(), atom) :: Macro.t()
  def to_quoted(ctx, fqn) do
    # TODO(codegen): Avoid the string round-trip by teaching the type-def
    # renderer to produce quoted AST directly.
    type_str = to_string(ctx, fqn)
    Code.string_to_quoted!(type_str)
  end

  # ── Formatting ─────────────────────────────────────────────────────

  defp format_type_def(_ctx, %{kind: :scalar, spec: spec}, _indent), do: spec

  defp format_type_def(ctx, %{kind: :ref, id: id}, _indent) do
    cond do
      name = ctx.names[id] ->
        "#{name}()"

      true ->
        "map()"
    end
  end

  defp format_type_def(ctx, %{kind: :list, inner: inner}, indent) do
    "list(#{format_type_def(ctx, inner, indent)})"
  end

  defp format_type_def(ctx, %{kind: :nullable, inner: inner}, indent) do
    "#{format_type_def(ctx, inner, indent)} | nil"
  end

  defp format_type_def(ctx, %{kind: :map_of, key: k, value: v}, indent) do
    "%{#{format_type_def(ctx, k, indent)} => #{format_type_def(ctx, v, indent)}}"
  end

  defp format_type_def(_ctx, %{kind: :enum, values: values}, _indent) do
    Enum.map_join(values, " | ", &inspect/1)
  end

  defp format_type_def(ctx, %{kind: :oneof, variants: variants}, indent) do
    variants
    |> Enum.map(fn {fname, type_def} ->
      "{:#{fname}, #{format_type_def(ctx, type_def, indent)}}"
    end)
    |> Enum.join(" | ")
  end

  defp format_type_def(ctx, %{kind: :map, fields: fields}, indent) do
    if fields == [] do
      "%{}"
    else
      pad = String.duplicate("  ", indent)
      inner_pad = String.duplicate("  ", indent + 1)

      inner =
        fields
        |> Enum.map(fn {name, %{type: type_def} = field} ->
          type_str = format_type_def(ctx, type_def, indent + 1)
          "#{field_key(field, name)} => #{type_str}"
        end)
        |> Enum.join(",\n#{inner_pad}")

      "%{\n#{inner_pad}#{inner}\n#{pad}}"
    end
  end

  defp format_type_def(_ctx, :placeholder, _indent), do: "map()"

  defp field_key(%{required: true}, name), do: "required(:#{name})"
  defp field_key(_field, name), do: "optional(:#{name})"

  # ── Topological sort ──────────────────────────────────────────────

  defp topo_sort(registry) do
    all_ids = MapSet.new(Map.keys(registry))

    graph =
      Map.new(registry, fn {id, type_def} ->
        deps = collect_deps(type_def, all_ids)
        {id, deps}
      end)

    reverse_graph =
      Enum.reduce(graph, Map.new(all_ids, &{&1, []}), fn {id, deps}, acc ->
        Enum.reduce(deps, acc, fn dep, acc ->
          Map.update(acc, dep, [id], &[id | &1])
        end)
      end)

    reverse_in_degree =
      Enum.reduce(reverse_graph, Map.new(all_ids, &{&1, 0}), fn {_id, dependents}, acc ->
        Enum.reduce(dependents, acc, fn dep, acc ->
          Map.update(acc, dep, 1, &(&1 + 1))
        end)
      end)

    sorted = kahns(reverse_graph, reverse_in_degree, all_ids)

    if length(sorted) < MapSet.size(all_ids) do
      missing = MapSet.difference(all_ids, MapSet.new(sorted))
      sorted ++ Enum.sort(missing)
    else
      sorted
    end
  end

  defp collect_deps(:placeholder, _all_ids), do: []

  defp collect_deps(%{kind: :map, fields: fields}, all_ids) do
    Enum.flat_map(fields, fn {_name, %{type: type_def}} ->
      collect_type_deps(type_def, all_ids)
    end)
  end

  defp collect_deps(_, _all_ids), do: []

  defp collect_type_deps(%{kind: :ref, id: id}, all_ids) do
    if MapSet.member?(all_ids, id), do: [id], else: []
  end

  defp collect_type_deps(%{kind: :list, inner: inner}, all_ids),
    do: collect_type_deps(inner, all_ids)

  defp collect_type_deps(%{kind: :nullable, inner: inner}, all_ids),
    do: collect_type_deps(inner, all_ids)

  defp collect_type_deps(%{kind: :map_of, key: k, value: v}, all_ids),
    do: collect_type_deps(k, all_ids) ++ collect_type_deps(v, all_ids)

  defp collect_type_deps(%{kind: :oneof, variants: variants}, all_ids) do
    Enum.flat_map(variants, fn {_name, type_def} -> collect_type_deps(type_def, all_ids) end)
  end

  defp collect_type_deps(_, _all_ids), do: []

  defp kahns(graph, in_degree, all) do
    queue =
      all
      |> Enum.filter(&(Map.get(in_degree, &1, 0) == 0))
      |> Enum.sort()

    kahns_loop(queue, graph, in_degree, [])
  end

  defp kahns_loop([], _graph, _in_degree, result), do: Enum.reverse(result)

  defp kahns_loop([node | rest], graph, in_degree, result) do
    dependents = Map.get(graph, node, [])

    {new_queue, new_in_degree} =
      Enum.reduce(dependents, {[], in_degree}, fn dep, {new_q, deg} ->
        new_deg = Map.update!(deg, dep, &(&1 - 1))

        if new_deg[dep] == 0,
          do: {[dep | new_q], new_deg},
          else: {new_q, new_deg}
      end)

    kahns_loop(rest ++ Enum.sort(new_queue), graph, new_in_degree, [node | result])
  end
end

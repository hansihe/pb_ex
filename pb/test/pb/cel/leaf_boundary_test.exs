defmodule CEL.LeafBoundaryTest do
  # The CEL leaf (`lib/cel.ex` and `lib/cel/`) is on its way to its own
  # project and must not depend on protobuf: its modules may only reference each
  # other, the Elixir and Erlang standard libraries, and the allowlist below.
  # Leaf modules are told from the protobuf binding's `PB.CEL.*` modules
  # (`lib/pb_cel/`) by the file they are compiled from. References are read from
  # each leaf module's abstract code (calls, structs, types, behaviours and
  # module atoms) and, for macros, which leave no trace there, from
  # `mix xref`'s compile-time edges. Separate projects take over once they exist.
  use ExUnit.Case, async: false

  # {leaf module, referenced module} => why the reference stays for now.
  @allowed %{
    # `schema:` defaults the providers to the protobuf binding, which
    # `CEL.Env.build/1` callers rely on; resolved in step 2 of the split.
    {CEL.Env, PB.CEL.MessageSchema} => :env_schema_default,
    {CEL.Env, PB.CEL.MessageRuntime} => :env_schema_default,
    # Option errors are raised as `PB.OptionError`, as documented.
    {CEL.Env, PB.OptionError} => :public_exception,
    {CEL.Options, PB.OptionError} => :public_exception
  }

  @root Path.expand("../../..", __DIR__)

  test "the CEL leaf references only itself, the standard library and the allowlist" do
    leaf = leaf_modules()
    assert CEL in leaf and CEL.Value in leaf
    refute PB.CEL.MessageRuntime in leaf

    violations =
      for module <- Enum.sort(leaf),
          referenced <- references(module),
          not MapSet.member?(leaf, referenced),
          not stdlib?(referenced),
          not Map.has_key?(@allowed, {module, referenced}),
          do: {module, referenced}

    assert violations == []
  end

  test "the CEL leaf needs nothing outside itself at compile time" do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Task.rerun("xref", ["graph", "--format", "json", "--output", "-"])
      end)

    violations =
      for {source, sinks} <- JSON.decode!(output),
          leaf_file?(source),
          {sink, "compile"} <- sinks,
          not leaf_file?(sink),
          do: {source, sink}

    assert violations == []
  end

  test "every allowlisted reference is still needed" do
    leaf = leaf_modules()

    for {module, referenced} <- Map.keys(@allowed) do
      assert module in leaf and referenced in references(module),
             "#{inspect(module)} no longer references #{inspect(referenced)}; drop it from @allowed"
    end
  end

  defp leaf_modules do
    {:ok, modules} = :application.get_key(:pb, :modules)

    MapSet.new(for module <- modules, leaf_file?(source(module)), do: module)
  end

  defp source(module) do
    source = module.module_info(:compile) |> Keyword.fetch!(:source) |> List.to_string()
    Path.relative_to(source, @root)
  end

  defp leaf_file?("lib/cel.ex"), do: true
  defp leaf_file?("lib/cel/" <> _rest), do: true
  defp leaf_file?(_path), do: false

  defp references(module) do
    {:ok, {^module, [abstract_code: {:raw_abstract_v1, forms}]}} =
      module |> :code.which() |> :beam_lib.chunks([:abstract_code])

    forms |> collect(MapSet.new()) |> MapSet.delete(module)
  end

  # Remote calls and remote types name Erlang modules too; any other atom
  # counts only when it is an Elixir module name.
  defp collect({:remote, _anno, {:atom, _, module}, _fun} = form, acc),
    do: form |> Tuple.to_list() |> collect(MapSet.put(acc, module))

  defp collect({:remote_type, _anno, [{:atom, _, module} | _rest]} = form, acc),
    do: form |> Tuple.to_list() |> collect(MapSet.put(acc, module))

  defp collect(atom, acc) when is_atom(atom) do
    if String.starts_with?(Atom.to_string(atom), "Elixir."), do: MapSet.put(acc, atom), else: acc
  end

  defp collect(term, acc) when is_tuple(term), do: term |> Tuple.to_list() |> collect(acc)
  defp collect([head | tail], acc), do: collect(tail, collect(head, acc))
  defp collect(_term, acc), do: acc

  defp stdlib?(module) do
    Code.ensure_loaded?(module) and
      (:code.which(module) == :preloaded or
         match?(
           {:ok, app} when app in [:elixir, :kernel, :stdlib],
           :application.get_application(module)
         ))
  end
end

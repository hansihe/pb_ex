defmodule CEL.LeafBoundaryTest do
  # The CEL leaf (`lib/cel.ex` and `lib/cel/`) is on its way to its own
  # project and must not depend on protobuf: its modules may only reference each
  # other, the Elixir and Erlang standard libraries, and the allowlist below.
  # Leaf modules are told from the protobuf binding's `PB.CEL.*` modules
  # (`lib/pb_cel/`) by the file they are compiled from. References are read from
  # each leaf module's abstract code (calls, structs, types, behaviours and
  # module atoms) and, for macros, which leave no trace there, from
  # `mix xref`'s compile-time edges. Separate projects take over once they exist.
  #
  # Names of message and enum types are their provider's, so the leaf must
  # never make an atom from text: the abstract code may not call any of the
  # functions that do.
  use ExUnit.Case, async: false

  # {leaf module, referenced module} => why the reference stays for now.
  @allowed %{}

  @atom_makers [
    {String, :to_atom, 1},
    {String, :to_existing_atom, 1},
    {List, :to_atom, 1},
    {List, :to_existing_atom, 1},
    {:erlang, :binary_to_atom, 1},
    {:erlang, :binary_to_atom, 2},
    {:erlang, :binary_to_existing_atom, 1},
    {:erlang, :binary_to_existing_atom, 2},
    {:erlang, :list_to_atom, 1},
    {:erlang, :list_to_existing_atom, 1}
  ]

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

  test "the CEL leaf never makes an atom from text" do
    calls =
      for module <- Enum.sort(leaf_modules()),
          {callee, function, arity} <- remote_calls(module),
          {callee, function, arity} in @atom_makers,
          do: {module, {callee, function, arity}}

    assert calls == []
  end

  # Elixir inlines `String.to_existing_atom/1` to the `:erlang` call.
  test "the atom check sees such calls in abstract code" do
    assert Enum.any?(@atom_makers, &(&1 in remote_calls(PB.CEL.MessageSchema)))
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
    module |> abstract_code() |> collect(MapSet.new()) |> MapSet.delete(module)
  end

  defp abstract_code(module) do
    {:ok, {^module, [abstract_code: {:raw_abstract_v1, forms}]}} =
      module |> :code.which() |> :beam_lib.chunks([:abstract_code])

    forms
  end

  # Calls through a variable module or function are not found; the leaf has
  # none that make atoms.
  defp remote_calls(module), do: module |> abstract_code() |> collect_calls(MapSet.new())

  defp collect_calls({:call, _anno, {:remote, _, {:atom, _, mod}, {:atom, _, fun}}, args}, acc),
    do: collect_calls(args, MapSet.put(acc, {mod, fun, length(args)}))

  defp collect_calls(term, acc) when is_tuple(term),
    do: term |> Tuple.to_list() |> collect_calls(acc)

  defp collect_calls([head | tail], acc), do: collect_calls(tail, collect_calls(head, acc))
  defp collect_calls(_term, acc), do: acc

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

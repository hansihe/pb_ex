defmodule PB.CoreBoundaryTest do
  # PB core (everything in `lib/` but the CEL binding, `lib/pb_cel/`) is on its
  # way to a project of its own and must not depend on the binding;
  # protovalidate, in pb_validate, already is one. Modules are told apart by the
  # file they are compiled from. References are read from each core module's abstract code
  # (calls, structs, types, behaviours and module atoms) and, for macros, which
  # leave no trace there, from `mix xref`'s compile-time edges. Separate
  # projects take over once they exist.
  use ExUnit.Case, async: false

  @root Path.expand("../..", __DIR__)

  test "core modules reference no CEL binding module" do
    {core, outside} = modules() |> Enum.split_with(&core_file?(source(&1)))
    outside = MapSet.new(outside)
    assert PB.Schema in core and PB.CEL.FieldReader in outside

    violations =
      for module <- Enum.sort(core),
          referenced <- references(module),
          MapSet.member?(outside, referenced),
          do: {module, referenced}

    assert violations == []
  end

  test "core needs no CEL binding file at compile time" do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Task.rerun("xref", ["graph", "--format", "json", "--output", "-"])
      end)

    violations =
      for {source, sinks} <- JSON.decode!(output),
          core_file?(source),
          {sink, "compile"} <- sinks,
          lib_file?(sink) and not core_file?(sink),
          do: {source, sink}

    assert violations == []
  end

  defp modules do
    {:ok, modules} = :application.get_key(:pb, :modules)
    Enum.filter(modules, &lib_file?(source(&1)))
  end

  defp source(module) do
    source = module.module_info(:compile) |> Keyword.fetch!(:source) |> List.to_string()
    Path.relative_to(source, @root)
  end

  defp lib_file?(path), do: String.starts_with?(path, "lib/")

  defp core_file?("lib/pb_cel/" <> _rest), do: false
  defp core_file?(path), do: lib_file?(path)

  defp references(module) do
    {:ok, {^module, [abstract_code: {:raw_abstract_v1, forms}]}} =
      module |> :code.which() |> :beam_lib.chunks([:abstract_code])

    forms |> collect(MapSet.new()) |> MapSet.delete(module)
  end

  defp collect(atom, acc) when is_atom(atom), do: MapSet.put(acc, atom)
  defp collect(term, acc) when is_tuple(term), do: term |> Tuple.to_list() |> collect(acc)
  defp collect([head | tail], acc), do: collect(tail, collect(head, acc))
  defp collect(_term, acc), do: acc
end

defmodule CEL.AtomsTest do
  # Names of message and enum types are their provider's, so CEL must never
  # make an atom from text: the abstract code of its modules may not call any
  # of the functions that do.
  use ExUnit.Case, async: true

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

  # A module that makes an atom from text, for checking that the scan sees it.
  # Test files compile without debug info unless a module asks for it.
  {:module, _module, beam, _result} =
    defmodule AtomMaker do
      @compile :debug_info
      def name(text), do: String.to_existing_atom(text)
    end

  @atom_maker_beam beam

  test "CEL never makes an atom from text" do
    {:ok, modules} = :application.get_key(:cel_ex, :modules)
    assert CEL in modules and CEL.Value in modules

    calls =
      for module <- Enum.sort(modules),
          {callee, function, arity} <- remote_calls(module),
          {callee, function, arity} in @atom_makers,
          do: {module, {callee, function, arity}}

    assert calls == []
  end

  # Elixir inlines `String.to_existing_atom/1` to the `:erlang` call.
  test "the atom check sees such calls in abstract code" do
    assert Enum.any?(@atom_makers, &(&1 in remote_calls(@atom_maker_beam)))
  end

  # Calls through a variable module or function are not found; CEL has none
  # that make atoms.
  defp remote_calls(module_or_beam),
    do: module_or_beam |> abstract_code() |> collect_calls(MapSet.new())

  defp abstract_code(module) when is_atom(module), do: module |> :code.which() |> abstract_code()

  defp abstract_code(beam) do
    {:ok, {_module, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(beam, [:abstract_code])

    forms
  end

  defp collect_calls({:call, _anno, {:remote, _, {:atom, _, mod}, {:atom, _, fun}}, args}, acc),
    do: collect_calls(args, MapSet.put(acc, {mod, fun, length(args)}))

  defp collect_calls(term, acc) when is_tuple(term),
    do: term |> Tuple.to_list() |> collect_calls(acc)

  defp collect_calls([head | tail], acc), do: collect_calls(tail, collect_calls(head, acc))
  defp collect_calls(_term, acc), do: acc
end

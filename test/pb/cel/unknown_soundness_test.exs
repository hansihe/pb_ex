defmodule PB.CEL.UnknownSoundnessTest do
  # Partial evaluation is sound when a known result with one unknown input is
  # the result for every concrete value of that input, and an unknown result
  # names only that input. Expressions are generated from a seeded random
  # grammar so failures reproduce with `mix test --seed`.
  use ExUnit.Case, async: true

  alias PB.CEL
  alias PB.CEL.Unknown

  @expressions 400
  @samples 12
  @vars [a: :int, b: :int, p: :bool, l: {:list, :int}]

  test "known results hold for every concrete value of the unknown input" do
    :rand.seed(:exsss, {ExUnit.configuration()[:seed], 0, 0})
    env = CEL.Env.build(vars: @vars)

    for _expression <- 1..@expressions do
      source = gen(:bool, 4, false)
      program = CEL.compile!(source, env)
      {unknown_var, unknown_type} = Enum.random(@vars)
      bindings = concrete_bindings()

      result = CEL.Program.eval(program, Map.put(bindings, unknown_var, {:unknown, :reason}))

      case result do
        {:ok, value} ->
          for _sample <- 1..@samples do
            concrete = Map.put(bindings, unknown_var, gen_value(unknown_type))

            assert CEL.Program.eval(program, concrete) == {:ok, value},
                   "#{source} with #{unknown_var} unknown returned #{inspect(value)}, " <>
                     "but with #{inspect(concrete)}"
          end

        {:unknown, unknown} ->
          name = Atom.to_string(unknown_var)
          assert Unknown.attributes(unknown) == MapSet.new([{:var, name}]), source
          assert source =~ ~r/\b#{name}\b/, source

        {:error, _error} ->
          :ok
      end
    end
  end

  defp concrete_bindings, do: Map.new(@vars, fn {name, type} -> {name, gen_value(type)} end)

  defp gen_value(:int), do: Enum.random(-3..3)
  defp gen_value(:bool), do: Enum.random([true, false])

  defp gen_value({:list, :int}),
    do: Enum.map(1..Enum.random(0..3)//1, fn _ -> gen_value(:int) end)

  # `local?` is true inside a comprehension body, where `i` is in scope.
  defp gen(:bool, 0, _local?), do: Enum.random(["p", "true", "false"])

  defp gen(:bool, depth, local?) do
    d = depth - 1

    case Enum.random(1..9) do
      1 -> "(#{gen(:int, d, local?)} #{Enum.random(~w[< <= == != > >=])} #{gen(:int, d, local?)})"
      2 -> "(#{gen(:bool, d, local?)} && #{gen(:bool, d, local?)})"
      3 -> "(#{gen(:bool, d, local?)} || #{gen(:bool, d, local?)})"
      4 -> "!#{gen(:bool, d, local?)}"
      5 -> "(#{gen(:bool, d, local?)} ? #{gen(:bool, d, local?)} : #{gen(:bool, d, local?)})"
      6 -> "(#{gen(:int, d, local?)} in #{gen(:list, d, local?)})"
      7 -> "#{gen(:list, d, local?)}.exists(i, #{gen(:bool, d, true)})"
      8 -> "#{gen(:list, d, local?)}.all(i, #{gen(:bool, d, true)})"
      9 -> gen(:bool, 0, local?)
    end
  end

  defp gen(:int, 0, local?) do
    Enum.random(["a", "b", "0", "1", "2"] ++ if(local?, do: ["i", "i"], else: []))
  end

  defp gen(:int, depth, local?) do
    d = depth - 1

    case Enum.random(1..7) do
      1 -> "(#{gen(:int, d, local?)} #{Enum.random(~w[+ - * / %])} #{gen(:int, d, local?)})"
      2 -> "(#{gen(:bool, d, local?)} ? #{gen(:int, d, local?)} : #{gen(:int, d, local?)})"
      3 -> "size(#{gen(:list, d, local?)})"
      4 -> "#{gen(:list, d, local?)}[#{gen(:int, d, local?)}]"
      _ -> gen(:int, 0, local?)
    end
  end

  defp gen(:list, 0, _local?), do: Enum.random(["l", "[0]", "[1, 2]"])

  defp gen(:list, depth, local?) do
    d = depth - 1

    case Enum.random(1..4) do
      1 -> "[#{gen(:int, d, local?)}, #{gen(:int, d, local?)}]"
      2 -> "#{gen(:list, d, local?)}.map(i, #{gen(:int, d, true)})"
      3 -> "#{gen(:list, d, local?)}.filter(i, #{gen(:bool, d, true)})"
      4 -> gen(:list, 0, local?)
    end
  end
end

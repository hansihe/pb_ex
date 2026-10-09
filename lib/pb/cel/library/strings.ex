defmodule PB.CEL.Library.Strings do
  @moduledoc false

  alias PB.CEL.Function
  alias PB.CEL.Function.Overload
  alias PB.CEL.Runtime.Strings, as: RuntimeStrings

  @function_specs [
    {"matches", [:global, :receiver], [{"matches", [:string, :string], :bool, :matches}],
     [{"matches_dyn", [:any, :any], :bool, :matches}]},
    {"charAt", [:receiver], [{"char_at", [:string, :int], :string, :char_at}],
     [{"char_at_dyn", [:any, :any], :string, :char_at}]},
    {"indexOf", [:receiver],
     [
       {"index_of", [:string, :string], :int, :index_of},
       {"index_of_index", [:string, :string, :int], :int, :index_of}
     ],
     [
       {"index_of_dyn", [:any, :any], :int, :index_of},
       {"index_of_index_dyn", [:any, :any, :any], :int, :index_of}
     ]},
    {"lastIndexOf", [:receiver],
     [
       {"last_index_of", [:string, :string], :int, :last_index_of},
       {"last_index_of_index", [:string, :string, :int], :int, :last_index_of}
     ],
     [
       {"last_index_of_dyn", [:any, :any], :int, :last_index_of},
       {"last_index_of_index_dyn", [:any, :any, :any], :int, :last_index_of}
     ]},
    {"lowerAscii", [:receiver], [{"lower_ascii", [:string], :string, :lower_ascii}],
     [{"lower_ascii_dyn", [:any], :string, :lower_ascii}]},
    {"upperAscii", [:receiver], [{"upper_ascii", [:string], :string, :upper_ascii}],
     [{"upper_ascii_dyn", [:any], :string, :upper_ascii}]},
    {"replace", [:receiver],
     [
       {"replace", [:string, :string, :string], :string, :replace},
       {"replace_limit", [:string, :string, :string, :int], :string, :replace}
     ],
     [
       {"replace_dyn", [:any, :any, :any], :string, :replace},
       {"replace_limit_dyn", [:any, :any, :any, :any], :string, :replace}
     ]},
    {"split", [:receiver],
     [
       {"split", [:string, :string], {:list, :string}, :split},
       {"split_limit", [:string, :string, :int], {:list, :string}, :split}
     ],
     [
       {"split_dyn", [:any, :any], {:list, :string}, :split},
       {"split_limit_dyn", [:any, :any, :any], {:list, :string}, :split}
     ]},
    {"substring", [:receiver],
     [
       {"substring", [:string, :int], :string, :substring},
       {"substring_range", [:string, :int, :int], :string, :substring}
     ],
     [
       {"substring_dyn", [:any, :any], :string, :substring},
       {"substring_range_dyn", [:any, :any, :any], :string, :substring}
     ]},
    {"trim", [:receiver], [{"trim", [:string], :string, :trim}],
     [{"trim_dyn", [:any], :string, :trim}]},
    {"join", [:receiver],
     [
       {"join", [{:list, :string}], :string, :join},
       {"join_separator", [{:list, :string}, :string], :string, :join}
     ],
     [
       {"join_dyn", [:any], :string, :join},
       {"join_separator_dyn", [:any, :any], :string, :join}
     ]},
    {"format", [:receiver], [{"format", [:string, :list], :string, :format}],
     [{"format_dyn", [:any, :any], :string, :format}]},
    {"quote", [{:namespace, "strings"}], [{"strings_quote", [:string], :string, :quote}],
     [{"strings_quote_dyn", [:any], :string, :quote}]},
    {"startsWith", [:receiver],
     [
       {"starts_with", [:string, :string], :bool, :starts_with},
       {"starts_with_bytes", [:bytes, :bytes], :bool, :starts_with}
     ], [{"starts_with_dyn", [:any, :any], :bool, :starts_with}]},
    {"endsWith", [:receiver],
     [
       {"ends_with", [:string, :string], :bool, :ends_with},
       {"ends_with_bytes", [:bytes, :bytes], :bool, :ends_with}
     ], [{"ends_with_dyn", [:any, :any], :bool, :ends_with}]},
    {"contains", [:receiver],
     [
       {"contains", [:string, :string], :bool, :contains},
       {"contains_bytes", [:bytes, :bytes], :bool, :contains}
     ], [{"contains_dyn", [:any, :any], :bool, :contains}]}
  ]

  @spec functions() :: [Function.t()]
  def functions do
    Enum.map(@function_specs, fn {name, modes, overload_specs, dynamic_specs} ->
      %Function{
        name: name,
        modes: modes,
        overloads: Enum.map(overload_specs, &build_overload/1),
        dynamic_overloads: Enum.map(dynamic_specs, &build_overload/1)
      }
    end)
  end

  defp build_overload({id, args, result, runtime}),
    do: %Overload{
      id: id,
      args: args,
      result: result,
      eval: {:mfa, {RuntimeStrings, runtime}}
    }
end

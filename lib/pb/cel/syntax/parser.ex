defmodule PB.CEL.Syntax.Parser do
  @moduledoc false

  alias PB.CEL.Error
  alias PB.CEL.Proto
  alias PB.CEL.Syntax.Builder
  alias PB.CEL.Syntax.Tokenizer

  @prec_conditional 1
  @prec_or 2
  @prec_and 3
  @prec_relation 4
  @prec_addition 5
  @prec_multiplication 6
  @prec_unary 7

  @max_source_bytes 100_000
  @max_recursion_depth 250

  @binary_ops %{
    "||" => {@prec_or, "_||_"},
    "&&" => {@prec_and, "_&&_"},
    "==" => {@prec_relation, "_==_"},
    "!=" => {@prec_relation, "_!=_"},
    "<" => {@prec_relation, "_<_"},
    "<=" => {@prec_relation, "_<=_"},
    ">=" => {@prec_relation, "_>=_"},
    ">" => {@prec_relation, "_>_"},
    "in" => {@prec_relation, "@in"},
    "+" => {@prec_addition, "_+_"},
    "-" => {@prec_addition, "_-_"},
    "*" => {@prec_multiplication, "_*_"},
    "/" => {@prec_multiplication, "_/_"},
    "%" => {@prec_multiplication, "_%_"}
  }

  @unary_ops %{"!" => "!_", "-" => "-_"}

  defmodule State do
    @moduledoc false
    defstruct [:tokens, :builder, :location, index: 0, depth: 0]
  end

  @spec parse(String.t(), keyword) :: {:ok, Proto.parsed_expr()} | {:error, Error.t()}
  def parse(source, opts \\ []) when is_binary(source) and is_list(opts) do
    with :ok <- check_source_size(source, opts),
         {:ok, tokens} <- Tokenizer.tokenize(source, opts) do
      state = %State{
        tokens: List.to_tuple(tokens),
        builder: Builder.new(source, opts),
        location: Keyword.get(opts, :location)
      }

      with {:ok, expr, state} <- parse_expr(state, 0),
           :ok <- expect_eof(state) do
        {:ok, Builder.parsed(state.builder, expr)}
      end
    end
  end

  defp parse_expr(%State{} = state, min_prec) do
    with {:ok, state} <- descend(state),
         {:ok, left, state} <- parse_prefix(state),
         {:ok, expr, state} <- parse_infix(state, left, min_prec) do
      {:ok, expr, ascend(state)}
    end
  end

  defp parse_prefix(%State{} = state) do
    token = current(state)

    cond do
      token[:kind] == :op and Map.has_key?(@unary_ops, token.value) ->
        state = advance(state)

        case {token.value, current(state)} do
          {"-", %{kind: :int_min_abs, value: value}} ->
            build(state, &Builder.int(&1, token.offset, -value), advance(state))

          _other ->
            with {:ok, operand, state} <- parse_expr(state, @prec_unary) do
              build_call(state, token.offset, Map.fetch!(@unary_ops, token.value), [operand])
            end
        end

      true ->
        with {:ok, expr, state} <- parse_primary(state) do
          parse_postfix(state, expr)
        end
    end
  end

  defp parse_primary(%State{} = state) do
    token = current(state)

    cond do
      token_kind?(token, :bool) ->
        build(state, &Builder.bool(&1, token.offset, token.value))
        |> advance_after_build(state)

      token_kind?(token, :null) ->
        build(state, &Builder.null(&1, token.offset))
        |> advance_after_build(state)

      token_kind?(token, :int) ->
        build(state, &Builder.int(&1, token.offset, token.value))
        |> advance_after_build(state)

      token_kind?(token, :int_min_abs) ->
        error(token, "int literal exceeds int64 range")

      token_kind?(token, :uint) ->
        build(state, &Builder.uint(&1, token.offset, token.value))
        |> advance_after_build(state)

      token_kind?(token, :double) ->
        build(state, &Builder.double(&1, token.offset, token.value))
        |> advance_after_build(state)

      token_kind?(token, :string) ->
        build(state, &Builder.string(&1, token.offset, token.value))
        |> advance_after_build(state)

      token_kind?(token, :bytes) ->
        build(state, &Builder.bytes(&1, token.offset, token.value))
        |> advance_after_build(state)

      punct?(token, "(") ->
        parse_group(state)

      punct?(token, "[") ->
        parse_list(state)

      punct?(token, "{") ->
        parse_map(state)

      message_path?(state) ->
        parse_message(state)

      token_kind?(token, :ident) or punct?(token, ".") ->
        parse_ident_or_call(state)

      true ->
        error(token, "expected expression")
    end
  end

  defp advance_after_build({expr, builder}, %State{} = state) do
    {:ok, expr, %State{state | builder: builder} |> advance()}
  end

  defp parse_group(state) do
    with {:ok, state} <- expect_punct(state, "("),
         {:ok, expr, state} <- parse_expr(state, 0),
         {:ok, state} <- expect_punct(state, ")") do
      {:ok, expr, state}
    end
  end

  defp parse_ident_or_call(%State{} = state) do
    token = current(state)
    pos = token.offset

    with {:ok, name, state} <- parse_primary_name(state) do
      if punct?(current(state), "(") do
        with {:ok, args, state} <- parse_args(state) do
          build_call(state, pos, name, args)
        end
      else
        build_ident(state, pos, name)
      end
    end
  end

  defp parse_primary_name(state) do
    if punct?(current(state), ".") do
      state = advance(state)

      case current(state) do
        %{kind: :ident, value: name} -> {:ok, "." <> name, advance(state)}
        token -> error(token, "expected identifier after '.'")
      end
    else
      case current(state) do
        %{kind: :ident, value: name} -> {:ok, name, advance(state)}
        token -> error(token, "expected identifier")
      end
    end
  end

  defp parse_postfix(%State{} = state, expr) do
    token = current(state)

    cond do
      punct?(token, ".") ->
        parse_select_or_receiver_call(state, expr)

      punct?(token, "[") ->
        parse_index(state, expr)

      true ->
        {:ok, expr, state}
    end
  end

  defp parse_select_or_receiver_call(state, target) do
    dot = current(state)
    state = advance(state)
    {optional?, state} = optional_marker(state)
    selector_pos = current(state).offset

    with {:ok, selector, state} <- expect_selector(state) do
      cond do
        optional? ->
          with {:ok, expr, state} <-
                 build_optional_select(state, dot.offset, target, selector, selector_pos) do
            parse_postfix(state, expr)
          end

        punct?(current(state), "(") ->
          with {:ok, args, state} <- parse_args(state),
               {:ok, expr, state} <- build_call(state, dot.offset, selector, args, target) do
            parse_postfix(state, expr)
          end

        true ->
          with {:ok, expr, state} <- build_select(state, dot.offset, target, selector) do
            parse_postfix(state, expr)
          end
      end
    end
  end

  defp parse_index(state, target) do
    open = current(state)

    with {:ok, state} <- expect_punct(state, "["),
         {optional?, state} = optional_marker(state),
         {:ok, index, state} <- parse_expr(state, 0),
         {:ok, state} <- expect_punct(state, "]"),
         function = if(optional?, do: "_[?_]", else: "_[_]"),
         {:ok, expr, state} <- build_call(state, open.offset, function, [target, index]) do
      parse_postfix(state, expr)
    end
  end

  defp parse_infix(%State{} = state, left, min_prec) do
    token = current(state)

    cond do
      token[:kind] == :op and token.value == "?" and @prec_conditional >= min_prec ->
        parse_conditional(state, left, min_prec)

      binary = binary_op(token) ->
        {prec, function} = binary

        if prec >= min_prec do
          state = advance(state)

          with {:ok, right, state} <- parse_expr(state, prec + 1),
               {:ok, expr, state} <- build_call(state, token.offset, function, [left, right]) do
            parse_infix(state, expr, min_prec)
          end
        else
          {:ok, left, state}
        end

      true ->
        {:ok, left, state}
    end
  end

  defp parse_conditional(state, condition, _min_prec) do
    token = current(state)
    state = advance(state)

    with {:ok, true_expr, state} <- parse_expr(state, @prec_conditional + 1),
         {:ok, state} <- expect_op(state, ":"),
         {:ok, false_expr, state} <- parse_expr(state, @prec_conditional),
         {:ok, expr, state} <-
           build_call(state, token.offset, "_?_:_", [condition, true_expr, false_expr]) do
      parse_infix(state, expr, @prec_conditional)
    end
  end

  defp binary_op(%{kind: :op, value: op}), do: Map.get(@binary_ops, op)
  defp binary_op(_token), do: nil

  defp parse_args(state) do
    with {:ok, state} <- expect_punct(state, "(") do
      if punct?(current(state), ")") do
        {:ok, [], advance(state)}
      else
        parse_args_loop(state, [])
      end
    end
  end

  defp parse_args_loop(state, acc) do
    with {:ok, expr, state} <- parse_expr(state, 0) do
      cond do
        punct?(current(state), ",") ->
          state = advance(state)

          if punct?(current(state), ")") do
            error(current(state), "expected expression after ','")
          else
            parse_args_loop(state, [expr | acc])
          end

        punct?(current(state), ")") ->
          {:ok, Enum.reverse([expr | acc]), advance(state)}

        true ->
          error(current(state), "expected ',' or ')'")
      end
    end
  end

  defp parse_list(state) do
    open = current(state)

    with {:ok, state} <- expect_punct(state, "[") do
      if punct?(current(state), "]") do
        build(state, &Builder.list(&1, open.offset, []), advance(state))
      else
        parse_list_loop(state, open.offset, 0, [], [])
      end
    end
  end

  defp parse_list_loop(state, pos, index, acc, optional_indices) do
    {optional?, state} = optional_marker(state)

    with {:ok, expr, state} <- parse_expr(state, 0) do
      optional_indices = if optional?, do: [index | optional_indices], else: optional_indices

      cond do
        punct?(current(state), ",") ->
          state = advance(state)

          if punct?(current(state), "]") do
            build_list(state, pos, [expr | acc], optional_indices, advance(state))
          else
            parse_list_loop(state, pos, index + 1, [expr | acc], optional_indices)
          end

        punct?(current(state), "]") ->
          build_list(state, pos, [expr | acc], optional_indices, advance(state))

        true ->
          error(current(state), "expected ',' or ']'")
      end
    end
  end

  defp parse_map(state) do
    open = current(state)

    with {:ok, state} <- expect_punct(state, "{") do
      if punct?(current(state), "}") do
        build(state, &Builder.map(&1, open.offset, []), advance(state))
      else
        parse_map_loop(state, open.offset, [])
      end
    end
  end

  defp parse_map_loop(state, pos, acc) do
    entry_pos = current(state).offset
    {optional?, state} = optional_marker(state)

    with {:ok, key, state} <- parse_expr(state, 0),
         {:ok, state} <- expect_op(state, ":"),
         {:ok, value, state} <- parse_expr(state, 0) do
      entry = {key, value, entry_pos, optional?}

      cond do
        punct?(current(state), ",") ->
          state = advance(state)

          if punct?(current(state), "}") do
            build(state, &Builder.map(&1, pos, Enum.reverse([entry | acc])), advance(state))
          else
            parse_map_loop(state, pos, [entry | acc])
          end

        punct?(current(state), "}") ->
          build(state, &Builder.map(&1, pos, Enum.reverse([entry | acc])), advance(state))

        true ->
          error(current(state), "expected ',' or '}'")
      end
    end
  end

  defp parse_message(state) do
    {message_name, state, message_pos} = take_message_path(state)

    with {:ok, state} <- expect_punct(state, "{") do
      if punct?(current(state), "}") do
        build(state, &Builder.message(&1, message_pos, message_name, []), advance(state))
      else
        parse_message_loop(state, message_pos, message_name, [])
      end
    end
  end

  defp parse_message_loop(state, pos, message_name, acc) do
    field_pos = current(state).offset
    {optional?, state} = optional_marker(state)

    with {:ok, field, state} <- expect_selector(state),
         {:ok, state} <- expect_op(state, ":"),
         {:ok, value, state} <- parse_expr(state, 0) do
      entry = {field, value, field_pos, optional?}

      cond do
        punct?(current(state), ",") ->
          state = advance(state)

          if punct?(current(state), "}") do
            build(
              state,
              &Builder.message(&1, pos, message_name, Enum.reverse([entry | acc])),
              advance(state)
            )
          else
            parse_message_loop(state, pos, message_name, [entry | acc])
          end

        punct?(current(state), "}") ->
          build(
            state,
            &Builder.message(&1, pos, message_name, Enum.reverse([entry | acc])),
            advance(state)
          )

        true ->
          error(current(state), "expected ',' or '}'")
      end
    end
  end

  defp message_path?(state) do
    case scan_message_path(state) do
      {_name, path_state, _pos} -> punct?(current(path_state), "{")
      nil -> false
    end
  end

  defp take_message_path(state) do
    scan_message_path(state)
  end

  defp scan_message_path(state) do
    start = state
    start_pos = current(state).offset

    {absolute?, state} =
      if punct?(current(state), "."), do: {true, advance(state)}, else: {false, state}

    case current(state) do
      %{kind: :ident, value: first} ->
        state = advance(state)
        scan_message_path_segments(state, [first], absolute?, start_pos)

      _token ->
        if absolute?, do: nil, else: scan_message_path_segments(start, [], false, start_pos)
    end
  end

  defp scan_message_path_segments(state, segments, absolute?, start_pos) do
    if punct?(current(state), ".") and token_kind?(peek(state, 1), :ident) do
      segment = peek(state, 1).value
      state = state |> advance() |> advance()
      scan_message_path_segments(state, [segment | segments], absolute?, start_pos)
    else
      if segments == [] do
        nil
      else
        name = segments |> Enum.reverse() |> Enum.join(".")
        name = if absolute?, do: "." <> name, else: name
        {name, state, start_pos}
      end
    end
  end

  defp expect_selector(state) do
    case current(state) do
      %{kind: :ident, value: value} -> {:ok, value, advance(state)}
      %{kind: :reserved, value: value} -> {:ok, value, advance(state)}
      %{kind: :quoted_ident, value: value} -> {:ok, value, advance(state)}
      token -> error(token, "expected selector")
    end
  end

  defp expect_punct(state, value) do
    token = current(state)

    if punct?(token, value) do
      {:ok, advance(state)}
    else
      error(token, "expected #{inspect(value)}")
    end
  end

  defp expect_op(state, value) do
    token = current(state)

    if op?(token, value) do
      {:ok, advance(state)}
    else
      error(token, "expected #{inspect(value)}")
    end
  end

  defp expect_eof(state) do
    case current(state) do
      %{kind: :eof} -> :ok
      token -> error(token, "unexpected token")
    end
  end

  defp build(state, fun) do
    fun.(state.builder)
  end

  defp build(%State{} = state, fun, %State{} = next_state) do
    {expr, builder} = fun.(state.builder)
    {:ok, expr, %State{next_state | builder: builder}}
  end

  defp build_ident(state, pos, name) do
    build(state, &Builder.ident(&1, pos, name), state)
  end

  defp build_select(state, pos, target, field) do
    build(state, &Builder.select(&1, pos, target, field), state)
  end

  defp build_optional_select(state, pos, target, field, field_pos) do
    build(
      state,
      fn builder ->
        {field_expr, builder} = Builder.string(builder, field_pos, field)
        Builder.call(builder, pos, "_?._", [target, field_expr])
      end,
      state
    )
  end

  defp build_call(state, pos, function, args, target \\ nil) do
    build(state, &Builder.call(&1, pos, function, args, target), state)
  end

  defp build_list(state, pos, acc, optional_indices, next_state) do
    elements = Enum.reverse(acc)
    optional_indices = Enum.reverse(optional_indices)
    build(state, &Builder.list(&1, pos, elements, optional_indices), next_state)
  end

  defp check_source_size(source, _opts) when byte_size(source) <= @max_source_bytes do
    :ok
  end

  defp check_source_size(_source, opts) do
    {:error,
     Error.exception(
       phase: :parse,
       message: "CEL source exceeds maximum size of #{@max_source_bytes} bytes",
       offset: 0,
       location: Keyword.get(opts, :location)
     )}
  end

  defp descend(%State{depth: depth} = state) when depth < @max_recursion_depth do
    {:ok, %State{state | depth: depth + 1}}
  end

  defp descend(%State{} = state) do
    error(
      current(state),
      "CEL expression exceeds maximum parse recursion depth of #{@max_recursion_depth}"
    )
  end

  defp ascend(%State{depth: depth} = state), do: %State{state | depth: depth - 1}

  defp current(%State{} = state), do: token_at(state.tokens, state.index)
  defp peek(%State{} = state, offset), do: token_at(state.tokens, state.index + offset)

  defp token_at(tokens, index) when index < tuple_size(tokens), do: elem(tokens, index)
  defp token_at(_tokens, _index), do: nil
  defp advance(%State{} = state), do: %State{state | index: state.index + 1}

  defp optional_marker(state) do
    if op?(current(state), "?"), do: {true, advance(state)}, else: {false, state}
  end

  defp token_kind?(%{kind: kind}, kind), do: true
  defp token_kind?(_token, _kind), do: false

  defp punct?(%{kind: :punct, value: value}, value), do: true
  defp punct?(_token, _value), do: false

  defp op?(%{kind: :op, value: value}, value), do: true
  defp op?(_token, _value), do: false

  defp error(%{offset: offset}, message) do
    {:error, Error.exception(phase: :parse, message: message, offset: offset)}
  end
end

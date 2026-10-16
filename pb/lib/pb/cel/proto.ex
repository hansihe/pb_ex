defmodule PB.CEL.Proto do
  # Internal. Not part of the published API yet; may be exposed in a
  # later release. Original module doc retained below as reference.
  #
  # Runtime-backed protobuf types and codecs for CEL expression protos.
  #
  # The parser produces `cel.expr.ParsedExpr` values in the PB map shape.
  # Keeping these declarations in a small CEL-specific module gives the rest of
  # the implementation stable type names and codec entry points without exposing
  # the full bundled schema.
  @moduledoc false

  @type parsed_expr :: map()
  @type checked_expr :: map()
  @type eval_state :: map()
  @type expr_value :: map()
  @type value :: map()

  @type expr :: map()
  @type source_info :: map()
  @type constant :: map()
  @type type :: map()

  @roots [
    parsed_expr: :"cel.expr.ParsedExpr",
    checked_expr: :"cel.expr.CheckedExpr",
    eval_state: :"cel.expr.EvalState",
    expr_value: :"cel.expr.ExprValue",
    value: :"cel.expr.Value"
  ]

  # Reference the bundled main schema directly (it already contains the
  # cel.expr.* closure) instead of embedding a sliced copy. `PB.encode/decode`
  # resolve the module to its embedded compiled schema (O(1)).
  @schema PB.Schema.Main

  for {name, root} <- @roots do
    encode = :"encode_#{name}"
    encode! = :"encode_#{name}!"
    decode = :"decode_#{name}"
    decode! = :"decode_#{name}!"

    @spec unquote(encode)(term) :: {:ok, iodata} | {:error, PB.error()}
    @spec unquote(encode)(term, keyword) :: {:ok, iodata} | {:error, PB.error()}
    def unquote(encode)(data, opts \\ []) do
      PB.encode(data, @schema, unquote(root), opts)
    end

    @spec unquote(encode!)(term) :: iodata
    @spec unquote(encode!)(term, keyword) :: iodata
    def unquote(encode!)(data, opts \\ []) do
      PB.encode!(data, @schema, unquote(root), opts)
    end

    @spec unquote(decode)(binary) :: {:ok, term} | {:error, PB.error()}
    @spec unquote(decode)(binary, keyword) :: {:ok, term} | {:error, PB.error()}
    def unquote(decode)(binary, opts \\ []) do
      PB.decode(binary, @schema, unquote(root), decode_opts(opts))
    end

    @spec unquote(decode!)(binary) :: term
    @spec unquote(decode!)(binary, keyword) :: term
    def unquote(decode!)(binary, opts \\ []) do
      PB.decode!(binary, @schema, unquote(root), decode_opts(opts))
    end
  end

  defp decode_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: Keyword.put_new(opts, :defaults, true), else: opts
  end

  defp decode_opts(opts), do: opts
end

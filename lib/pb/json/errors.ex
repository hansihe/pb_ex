defmodule PB.JSON.Errors do
  @moduledoc false

  alias PB.{AdapterError, DecodeError, OptionError, SchemaError, ValueError}

  @pb_errors [SchemaError, ValueError, OptionError, DecodeError, AdapterError]

  @doc """
  Raises the `PB.Error` struct matching `kind`, built from `reason` and options.

  Options:
    * `:path` — JSON path (list of elements) to the error location.
    * `:details` — a map of extra typed fields (`:expected`, `:got`, `:min`,
      `:max`, …) merged onto the struct.
  """
  @spec raise!(atom, term, keyword) :: no_return
  def raise!(kind, reason, opts \\ []) do
    raise build(kind, reason, opts)
  end

  @doc """
  Runs `fun.()` and wraps the result in `{:ok, _}`, or catches a raised PB
  error and returns `{:error, _}` with the operation/message_name context
  attached.
  """
  @spec guard(atom, term, (-> term)) :: {:ok, term} | {:error, PB.Error.t()}
  def guard(operation, message_name, fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    error in @pb_errors ->
      {:error, put_json_context(error, operation, message_name)}
  end

  @doc """
  Builds an `{:error, _}` tuple for an unknown message-name target.
  """
  @spec unknown_message(atom, term) :: {:error, SchemaError.t()}
  def unknown_message(operation, message_name) do
    {:error,
     %SchemaError{
       kind: :unknown_message,
       operation: operation,
       message_name: message_name,
       name: message_name
     }}
  end

  defp build(:unknown_message, name, opts) do
    %SchemaError{kind: :unknown_message, name: name, path: path(opts)}
  end

  defp build(:unknown_field, field, opts) do
    %ValueError{kind: :unknown_field, path: path(opts), protobuf_message: details(opts)[:type_name]}
    |> put_reason(field)
  end

  defp build(:invalid_value, reason, opts) do
    d = details(opts)

    %ValueError{
      kind: :invalid_value,
      path: path(opts),
      reason: reason,
      expected: d[:expected],
      got: d[:got]
    }
  end

  defp build(:value_out_of_range, value, opts) do
    d = details(opts)
    %ValueError{kind: :value_out_of_range, path: path(opts), value: value, min: d[:min], max: d[:max]}
  end

  defp build(:unknown_enum_value, value, opts) do
    %ValueError{
      kind: :unknown_enum_value,
      path: path(opts),
      value: value,
      enum: details(opts)[:enum]
    }
  end

  defp build(:invalid_oneof, reason, opts) do
    %ValueError{kind: :invalid_oneof, path: path(opts), reason: reason}
  end

  defp build(:missing_required, _reason, opts) do
    %ValueError{kind: :missing_required, path: path(opts)}
  end

  defp build(:malformed_json, reason, opts) do
    %DecodeError{kind: :malformed_json, format: :json, path: path(opts), reason: reason}
  end

  defp build(:duplicate_field, reason, opts) do
    %DecodeError{
      kind: :duplicate_field,
      format: :json,
      path: path(opts),
      reason: reason,
      details: details(opts)
    }
  end

  defp path(opts), do: Keyword.get(opts, :path, [])
  defp details(opts), do: Keyword.get(opts, :details, %{})

  defp put_reason(%ValueError{} = error, reason), do: %{error | reason: reason}

  defp put_json_context(error, operation, message_name) do
    error
    |> maybe_put(:operation, operation)
    |> maybe_put(:message_name, message_name)
  end

  defp maybe_put(error, key, value) do
    case Map.fetch(error, key) do
      {:ok, nil} -> Map.put(error, key, value)
      _present_or_absent -> error
    end
  end
end

defmodule PB.Error do
  @moduledoc """
  Shared toolkit and umbrella type for PB's structured errors.

  PB does not raise a single catch-all error struct. Instead each failure
  category is its own `defexception`, with typed fields rather than a free-form
  details map:

    * `PB.SchemaError` — schema-resolution / introspection failures
      (`unknown_message`, `unknown_enum`, `unknown_service`,
      `unknown_extension`, `invalid_schema`).
    * `PB.ValueError` — input value/shape failures (`invalid_value`,
      `value_out_of_range`, `unknown_field`, `invalid_oneof`, enum-value
      problems, `missing_required`, `message_name_mismatch`, strict-projection
      failures, `absent`, …).
    * `PB.OptionError` — option failures (`unknown_options`, `invalid_option`,
      `invalid_options`).
    * `PB.DecodeError` — structurally invalid serialized input (`malformed`
      wire bytes, `malformed_json`, `malformed_text`, `duplicate_field`).
    * `PB.AdapterError` — an adapter `to_proto`/`from_proto` callback failed.

  Non-bang APIs return `{:error, error}` where `error` is one of the structs
  above (`t/0`); bang APIs raise the same struct. To handle any PB error
  uniformly, `rescue` the list of modules or match with `is_exception/1`.

  Each struct carries `:operation` (the entry point that produced it) and
  `:message_name` for context; the value/decode/adapter/schema structs also
  carry a `:path` locating the offending field. This module holds the shared
  pieces: the `t/0` union, the `operation`/`path_element` types, polymorphic
  `prepend_path/2`, and the formatting helpers each struct's `message/1` uses.
  """

  alias PB.{AdapterError, DecodeError, OptionError, SchemaError, ValueError}

  @typedoc "Path element used to locate the offending field in `:path`."
  @type path_element :: atom | {:index, non_neg_integer} | {:key, term}

  @typedoc "The operation that produced an error."
  @type operation ::
          :encode
          | :decode
          | :normalize
          | :json_encode
          | :json_decode
          | :text_decode
          | :text_encode
          | :validate
          | :message_equal
          | :introspect

  @typedoc "Any PB error struct returned by `{:error, _}` or raised by a bang API."
  @type t ::
          SchemaError.t()
          | ValueError.t()
          | OptionError.t()
          | DecodeError.t()
          | AdapterError.t()

  @doc """
  Prepends a path prefix to an error that carries a `:path`.

  Polymorphic across every PB error struct; structs without a `:path` (e.g.
  `PB.OptionError`) are returned unchanged. Used to attach enclosing-field
  context as an error unwinds through nested encode/decode frames.
  """
  @spec prepend_path(t(), [path_element]) :: t()
  def prepend_path(error, []), do: error

  def prepend_path(%{path: path} = error, prefix) when is_list(prefix) do
    %{error | path: prefix ++ path}
  end

  def prepend_path(error, _prefix), do: error

  @doc false
  def context(base, operation, message_name) do
    case {operation, message_name} do
      {nil, _message_name} -> base
      {operation, nil} -> "PB failed to #{operation}: #{base}"
      {operation, message_name} -> "PB failed to #{operation} #{inspect(message_name)}: #{base}"
    end
  end

  @doc false
  def format_path([]), do: "<message>"

  def format_path(path) do
    Enum.reduce(path, "", fn
      {:index, index}, acc ->
        acc <> "[#{index}]"

      {:key, key}, acc ->
        acc <> "[#{inspect(key)}]"

      part, "" when is_atom(part) ->
        Atom.to_string(part)

      part, acc when is_atom(part) ->
        acc <> "." <> Atom.to_string(part)

      part, "" ->
        inspect(part)

      part, acc ->
        acc <> "." <> inspect(part)
    end)
  end

  @doc false
  def format_location([]), do: ""
  def format_location(path), do: " at #{format_path(path)}"

  @doc false
  def format_reason(nil), do: ""
  def format_reason(reason), do: ": #{inspect(reason)}"
end

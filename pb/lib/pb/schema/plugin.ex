defmodule PB.Schema.Plugin do
  @moduledoc """
  Behaviour for libraries that compile their own data into a PB schema, such as
  protovalidate rules (e.g. `PB.Validate`).

  Plugins are listed in the `:plugins` option of `PB.compile/2` and
  `use PB.Schema`. Each entry is a module or a `{module, opts}` tuple:

      PB.compile(descriptor_set, plugins: [MyPlugin, {OtherPlugin, mode: :strict}])

  ## Compiling

  `c:compile/2` receives the final, prepared schema, after projections and
  runtime preparation, and returns it with the plugin's data added. Plugins run
  in list order, so a plugin sees the data of the plugins listed before it. The
  descriptor options of messages, fields, oneofs, and extensions are kept on
  the prepared schema, so a plugin reads its configuration from them.

  The compiled schema records which plugins compiled it, and with what options.
  When PB derives a new schema from a compiled one, such as narrowing it to a
  few root messages, it drops every recorded plugin's data and runs the plugins
  again on the result, so plugin data never describes a schema it no longer
  belongs to.

  ## Where plugin data lives

  A plugin stores its data under one key: its own module. That key may be set
  on the schema map itself, on a message (an entry of the schema's `:messages`),
  on a field or extension (an entry of a message's `:fields_by_name` or
  `:extensions_by_name`, or of the schema's `:extensions_by_name`), on a oneof
  (an entry of a message's `:oneofs`), and on an enum (an entry of the schema's
  `:enums`):

      schema = Map.put(schema, MyPlugin, %{built_at: now})
      field = Map.put(field, MyPlugin, %{checks: checks})

  These are the only places PB looks when it drops plugin data. Other copies of
  messages and fields in the prepared schema, such as `:fields_by_number`, are
  runtime indexes; plugins must not write to them, and should not read plugin
  data from them.

  The value under a plugin's key is the plugin's own business, but it must be
  plain data that `Macro.escape/1` accepts (structs, maps, compiled regexes),
  because `use PB.Schema` embeds the compiled schema in a module.

  ## Schema module functions

  A plugin may also implement `c:schema_functions/1`, returning code that
  `use PB.Schema` injects into every schema module listing the plugin. The code
  can call `__pb_schema__/0` for the module's compiled schema.
  """

  @typedoc "A `:plugins` entry: a plugin module, or a plugin module and its options."
  @type entry :: module() | {module(), keyword()}

  @doc """
  Adds the plugin's data to a prepared `schema`.

  `opts` are the options given with the plugin's entry, `[]` for a bare module.
  Raise to reject the schema or the options.
  """
  @callback compile(PB.schema(), opts :: keyword()) :: PB.schema()

  @doc """
  Returns quoted code to inject into a `use PB.Schema` module that lists this
  plugin, given the plugin's options.
  """
  @callback schema_functions(opts :: keyword()) :: Macro.t()

  @optional_callbacks schema_functions: 1

  @doc false
  # Normalizes a `:plugins` option value to `[{module, opts}]`, raising
  # `PB.OptionError` for an entry that is not a loaded plugin module.
  @spec __entries__!(term()) :: [{module(), keyword()}]
  def __entries__!(plugins) when is_list(plugins), do: Enum.map(plugins, &entry!/1)

  def __entries__!(plugins), do: raise(invalid(plugins, "expected a list of plugins"))

  defp entry!({module, opts} = entry) when is_atom(module) and is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise invalid(entry, "expected the options of #{inspect(module)} to be a keyword list")
    end

    {plugin!(entry, module), opts}
  end

  defp entry!(module) when is_atom(module), do: {plugin!(module, module), []}

  defp entry!(entry) do
    raise invalid(entry, "expected a plugin module or a {module, opts} tuple")
  end

  defp plugin!(entry, module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :compile, 2) do
      module
    else
      raise invalid(entry, "#{inspect(module)} is not a loaded module exporting compile/2")
    end
  end

  defp invalid(value, reason) do
    %PB.OptionError{
      kind: :invalid_option,
      operation: :compile,
      option: :plugins,
      value: value,
      reason: reason
    }
  end

  @doc false
  # Runs normalized plugin entries over a prepared schema, in order, and records
  # them on the result.
  @spec __run__(PB.schema(), [{module(), keyword()}]) :: PB.schema()
  def __run__(schema, plugins) do
    plugins
    |> Enum.reduce(schema, fn {module, opts}, schema -> module.compile(schema, opts) end)
    |> Map.put(:plugins, plugins)
  end

  @doc false
  # Drops the data of the plugins recorded on `schema` from every place the
  # moduledoc lets a plugin write to, ahead of re-preparing and re-running them.
  @spec __strip__(PB.schema()) :: PB.schema()
  def __strip__(schema) do
    case Map.get(schema, :plugins, []) do
      [] ->
        schema

      plugins ->
        keys = Enum.map(plugins, &elem(&1, 0))
        strip = &Map.drop(&1, keys)

        schema
        |> strip.()
        |> Map.update!(:messages, &map_values(&1, fn message -> strip_message(message, strip) end))
        |> Map.update!(:extensions_by_name, &map_values(&1, strip))
        |> Map.update!(:enums, &map_values(&1, strip))
    end
  end

  defp strip_message(message, strip) do
    message
    |> strip.()
    |> Map.update!(:fields_by_name, &map_values(&1, strip))
    |> Map.update!(:extensions_by_name, &map_values(&1, strip))
    |> Map.update!(:oneofs, &map_values(&1, strip))
  end

  defp map_values(map, fun), do: Map.new(map, fn {key, value} -> {key, fun.(value)} end)
end

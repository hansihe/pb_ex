defmodule PB.Runtime.RequiredFields do
  @moduledoc false

  @type required_field :: {PB.Schema.Compiled.field_name(), PB.Schema.Compiled.field_type()}
  @type nil_message :: :missing | :present

  @spec missing_path([required_field()], map(), [PB.Error.path_element()], keyword()) ::
          [PB.Error.path_element()] | nil
  def missing_path(required_fields, fields, path \\ [], opts \\ []) when is_map(fields) do
    nil_message = Keyword.get(opts, :nil_message, :missing)

    Enum.find_value(required_fields, fn {name, type} ->
      cond do
        not Map.has_key?(fields, name) ->
          path ++ [name]

        nil_message == :missing and type == :TYPE_MESSAGE and Map.get(fields, name) == nil ->
          path ++ [name]

        true ->
          nil
      end
    end)
  end
end

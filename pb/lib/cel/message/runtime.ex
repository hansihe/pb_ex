defmodule CEL.Message.Runtime do
  # Internal. Not part of the published API yet; may be exposed in a
  # later release. Original module doc retained below as reference.
  #
  # Behaviour for CEL runtime message access.
  @moduledoc false

  # TODO(CEL): The runtime boundary currently has separate select/select_ref and
  # optional variants. Consider a smaller access protocol over field refs plus a
  # literal fallback so evaluator implementations do not need parallel paths.
  @type schema_provider :: term()
  @type value :: CEL.Value.t()
  @type message :: {:message, atom() | String.t(), term()}

  @callback from_decoded(schema_provider(), atom(), term()) :: {:ok, value()} | {:error, term()}
  @callback from_literal(schema_provider(), atom(), [map()], boolean()) ::
              {:ok, value()} | :unknown | {:error, term()}
  @callback from_literal_message(schema_provider(), atom(), [map()]) ::
              {:ok, message()} | :unknown | {:error, term()}
  @callback select(schema_provider(), message(), String.t(), boolean()) ::
              {:ok, value()} | :not_applicable | {:error, term()}
  @callback select_ref(
              schema_provider(),
              message(),
              CEL.Message.Schema.field_ref(),
              boolean()
            ) ::
              {:ok, value()} | :not_applicable | {:error, term()}
  @callback optional_select(schema_provider(), value(), String.t()) ::
              {:ok, value()} | :not_applicable | {:error, term()}
  @callback optional_select_ref(schema_provider(), value(), CEL.Message.Schema.field_ref()) ::
              {:ok, value()} | :not_applicable | {:error, term()}
  @callback field_value(schema_provider(), map(), term()) :: {:ok, value()} | {:error, term()}
  @callback raw_fields_for_encode(schema_provider(), atom(), term()) ::
              {:ok, map()} | {:error, term()}
  @callback equal?(schema_provider(), message(), message()) :: {:ok, boolean()} | :not_applicable
  # Unpacks an `Any` payload: `type_url` and the encoded message, as in a
  # `cel.expr.Value` `object_value`.
  @callback from_any(schema_provider(), String.t(), binary()) :: {:ok, value()} | {:error, term()}
  # Packs a timestamp or duration value into an `Any` payload.
  @callback to_any(schema_provider(), value()) ::
              {:ok, %{type_url: String.t(), value: binary()}} | {:error, term()}
end

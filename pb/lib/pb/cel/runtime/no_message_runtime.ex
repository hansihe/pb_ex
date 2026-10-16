defmodule PB.CEL.Runtime.NoMessageRuntime do
  @moduledoc false

  # Default `PB.CEL.Message.Runtime` used when no protobuf binding is injected.
  #
  # The CEL subsystem does not depend on PB's protobuf message runtime; a host
  # that evaluates against protobuf messages (e.g. `PB.Validate`) injects
  # `PB.Validate.CEL.MessageRuntime` via `PB.CEL.Env`'s `:message_runtime`.
  # Without one, message operations are unsupported: this stub reports that
  # cleanly instead of crashing, while pure-value evaluation (which never reaches
  # a message runtime) keeps working.

  @behaviour PB.CEL.Message.Runtime

  @error {:error, :no_message_runtime}

  @impl true
  def from_decoded(_schema, _message, _decoded), do: @error

  @impl true
  def from_literal(_schema, _message, _fields, _wkt_unwrap?), do: @error

  @impl true
  def from_literal_message(_schema, _message, _fields), do: @error

  # Selection callbacks report :not_applicable (as the protobuf runtime does for
  # non-message operands) so the evaluator's non-message access paths still
  # produce their normal "no such key/field" diagnostics. A real message value
  # cannot exist without a runtime — from_decoded/from_literal error first.
  @impl true
  def select(_schema, _message, _field, _test_only?), do: :not_applicable

  @impl true
  def select_ref(_schema, _message, _field_ref, _test_only?), do: :not_applicable

  @impl true
  def optional_select(_schema, _value, _field), do: :not_applicable

  @impl true
  def optional_select_ref(_schema, _value, _field_ref), do: :not_applicable

  @impl true
  def field_value(_schema, _field, _value), do: @error

  @impl true
  def raw_fields_for_encode(_schema, _message, _fields), do: @error

  @impl true
  def equal?(_schema, _left, _right), do: :not_applicable
end

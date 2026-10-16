defmodule CEL.TypeProvider do
  @moduledoc """
  The message and enum types an environment knows, and how to read and build
  their values.

  A provider is a `{module, state}` tuple, given to `CEL.Env.build/1` as
  `:types`. `module` implements this behaviour, and every callback receives
  `state` first. Without `:types` there are no message or enum types; the
  CEL types, including the protobuf well-known types CEL builds in
  (`google.protobuf.Timestamp`, `Duration`, `Any`, `Value`, `ListValue`,
  `Struct` and the wrappers), are always available.

  `PB.CEL.types/1` is the provider for protobuf messages:

      CEL.Env.build(types: PB.CEL.types(MyApp.Schema), container: "my.pkg")

  ## Names

  A message, enum or extension name is whatever term the provider uses for
  it, an atom or a string. CEL only compares names with `==` and shows them
  with `to_string/1`, and never makes one from text itself: names in an
  expression become the provider's through `c:find_type/2`, field names
  through `c:find_field/3`. `to_string(name)` must be the fully qualified
  name that `c:find_type/2` resolves back to `name`.

  Values carry the provider's names: a message is `{:message, name, payload}`,
  where the provider owns `payload`, and an enum value is
  `{:enum, name, number}`.
  """

  @typedoc "A provider: a module implementing this behaviour, and its state."
  @type t :: {module, state}

  @typedoc "The provider's own state, passed to every callback."
  @type state :: term

  @typedoc "A message, enum or extension name, in the provider's form."
  @type name :: atom | String.t()

  @typedoc "A message value's payload, owned by the provider."
  @type payload :: term

  @doc """
  Resolves a fully qualified name, without a leading dot, to a message or
  enum type.
  """
  @callback find_type(state, String.t()) :: {:ok, :message | :enum, name} | :error

  @doc """
  Looks up a field of a message type by name, or an extension by its fully
  qualified name.
  """
  @callback find_field(state, message :: name, field :: String.t()) ::
              {:ok, CEL.Field.t()} | :error

  @doc "The number of an enum value, by the value's name."
  @callback enum_value(state, enum :: name, value :: String.t()) :: {:ok, integer} | :error

  @doc """
  The fields a message literal must set, by name. Optional; without it, none
  are required.
  """
  @callback required_fields(state, message :: name) :: [String.t()]

  @doc """
  Builds the value of a message literal from the fields it sets, in the order
  written. Fields set to an empty optional are left out.
  """
  @callback new_message(state, message :: name, [{CEL.Field.t(), CEL.Value.t()}]) ::
              {:ok, CEL.Value.t()} | {:error, term}

  @doc """
  Converts a variable's binding into a CEL value when the variable is declared
  with one of the provider's message or enum types and is not bound to a CEL
  value already.
  """
  @callback from_native(state, name, term) :: {:ok, CEL.Value.t()} | {:error, term}

  @doc """
  Reads a field of a message, its default when the field is unset. `field`
  is one `c:find_field/3` returned for the message's type.
  """
  @callback get_field(state, payload, CEL.Field.t()) :: {:ok, CEL.Value.t()} | {:error, term}

  @doc "Whether a field of a message is set, as CEL's `has()` tests it."
  @callback has_field?(state, payload, CEL.Field.t()) :: boolean

  @doc "Whether two messages of the type `message` are equal."
  @callback equal?(state, message :: name, payload, payload) :: boolean

  @doc """
  Unpacks the payload of a `google.protobuf.Any` literal: the message its type
  URL names, decoded from `value`. `:error` when the provider does not know
  the type, which leaves the literal an object value. Optional; without it,
  every `Any` literal stays an object value.
  """
  @callback unpack_any(state, type_url :: String.t(), value :: binary) ::
              {:ok, CEL.Value.t()} | :error | {:error, term}

  @optional_callbacks required_fields: 2, unpack_any: 3

  @doc false
  @spec required_callbacks() :: [{atom, arity}]
  def required_callbacks,
    do: __MODULE__.behaviour_info(:callbacks) -- __MODULE__.behaviour_info(:optional_callbacks)
end

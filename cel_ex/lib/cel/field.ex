defmodule CEL.Field do
  @moduledoc """
  A field of a message type, as a `CEL.TypeProvider` describes it.

    * `:name` — the field's name, as expressions select it.
    * `:type` — its `t:CEL.Type.t/0`: a list type for a repeated field, a
      map type for a map field, and the CEL type of a well-known type, such
      as `:timestamp` or `{:wrapper, :int}`, for a field holding one.
    * `:kind` — `:singular`, `:repeated` or `:map`.
    * `:oneof` — the name of the oneof the field is in, or `nil`.
    * `:ref` — the provider's own handle on the field. CEL keeps it in
      checked expressions and hands it back when reading the field, and
      never looks inside.

  The checker looks a field up once, with `c:CEL.TypeProvider.find_field/3`,
  and evaluation reads it through the same struct.
  """

  @enforce_keys [:name, :type]
  defstruct [:name, :type, kind: :singular, oneof: nil, ref: nil]

  @type kind :: :singular | :repeated | :map

  @type t :: %__MODULE__{
          name: String.t(),
          type: CEL.Type.t(),
          kind: kind,
          oneof: CEL.TypeProvider.name() | nil,
          ref: term
        }
end

defmodule PB.Schema.Projection do
  @moduledoc """
  Compiled projection metadata attached to a message in the schema.

  Projections drive message-level adapters, struct representations, identity
  oneofs, and unwrapped single-field messages. The projection for a given
  message is exposed on `%PB.Schema.Info.Message{}.projection`.

  Projections are configured at compile time via the `:projections` option on
  `PB.compile/2` and `use PB.Schema` (or in proto source via the
  `elixir.pb.v1` custom options). The struct itself is the resolved,
  post-merge form — callers should treat it as read-only.
  """

  @type t :: %__MODULE__{
          adapter: PB.Adapter.t() | nil,
          struct_mod: module() | nil,
          unwrap_field: atom() | nil,
          preserved_unknown_fields: :drop | :reject | {:field, atom()} | nil,
          extensions: :reject | {:field, atom()} | nil,
          oneofs: %{atom() => :identity}
        }

  defstruct [
    :adapter,
    :struct_mod,
    :unwrap_field,
    :preserved_unknown_fields,
    :extensions,
    oneofs: %{}
  ]
end

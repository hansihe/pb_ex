defmodule PB.WellKnownTypes do
  @moduledoc """
  Native adapters for protobuf well-known types.

  `projections/1` returns ready-to-use entries for the `:projections` option of
  `PB.compile/2` and `PB.Schema`. The adapters are opt-in — nothing is applied
  to a schema that does not register them.

      PB.compile(descriptor_set,
        projections: PB.WellKnownTypes.projections([:time, :wrappers, :json])
      )

  ## Representations

  Each group maps a set of well-known messages to a native Elixir value:

  ### `:time`

    * `google.protobuf.Timestamp` → `{:timestamp, unix_nanoseconds}`
    * `google.protobuf.Duration` → `{:duration, nanoseconds}`

  Integer nanoseconds keep protobuf precision intact. Higher-level
  integrations can expose lossy `DateTime` / `Duration` forms explicitly via a
  custom `PB.Adapter`.

  ### `:wrappers`

  The scalar wrapper messages unwrap to their bare scalar value (or `nil` when
  absent):

    * `google.protobuf.{Int32,Int64,UInt32,UInt64}Value` → `integer`
    * `google.protobuf.{Float,Double}Value` → `float`
    * `google.protobuf.BoolValue` → `boolean`
    * `google.protobuf.StringValue` → `String.t()`
    * `google.protobuf.BytesValue` → `binary`

  ### `:json`

  The JSON-value messages map to JSON-shaped Elixir terms:

    * `google.protobuf.Value` → `nil | boolean | number | String.t() | list | map`
    * `google.protobuf.ListValue` → `list`
    * `google.protobuf.Struct` → `map` with string keys

  See [Adapters and well-known types](adapters-and-well-known-types.html) for
  how adapters compose with encode, decode, JSON, and validation.
  """

  @type group :: :wrappers | :json | :time

  @typedoc "Native representation of `google.protobuf.Timestamp` (`:time` group)."
  @type timestamp :: {:timestamp, integer()}

  @typedoc "Native representation of `google.protobuf.Duration` (`:time` group)."
  @type duration :: {:duration, integer()}

  @doc """
  Returns PB projection entries for a well-known type group or list of
  groups.
  """
  @spec projections(group | [group]) :: [{PB.message_name(), keyword()}]
  def projections(:wrappers), do: PB.WellKnownTypes.Wrappers.projections()
  def projections(:json), do: PB.WellKnownTypes.Json.projections()
  def projections(:time), do: PB.WellKnownTypes.Time.projections()

  def projections(groups) when is_list(groups) do
    Enum.flat_map(groups, &projections/1)
  end

  def projections(group) do
    raise ArgumentError, "unknown PB well-known type projection group #{inspect(group)}"
  end
end

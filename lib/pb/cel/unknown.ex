defmodule PB.CEL.Unknown do
  # Internal. Not part of the published API yet; may be exposed in a
  # later release. Original module doc retained below as reference.
  #
  # The result of evaluating a CEL expression whose outcome depends on inputs
  # that are not known, in the spirit of cel-go's `types.Unknown`.
  #
  # An unknown carries the set of entries it depends on. Each entry pairs an
  # attribute with the opaque reason the caller supplied:
  #
  #   * `{:var, name}` — a top-level variable bound to `{:unknown, reason}`.
  #   * `{:call, function, expr_id}` — a custom function call that returned
  #     `{:unknown, reason}`.
  #
  # Bind a variable as unknown by passing `{:unknown, reason}` (or an existing
  # `PB.CEL.Unknown`, to forward one result into another evaluation):
  #
  #     {:unknown, unknown} =
  #       PB.CEL.eval("x < 30 && y > 1", %{x: {:unknown, :timeout}, y: {:unknown, :missing}}, env)
  #
  #     PB.CEL.Unknown.entries(unknown)
  #     #=> [{{:var, "x"}, :timeout}, {{:var, "y"}, :missing}]
  #
  # Operators that can decide their result without an input do so: `false &&
  # x` is `false` and `true || x` is `true`. Every other operation that reads
  # an unknown returns an unknown, merging the entries of all unknown operands.
  # When an operand of a strict operation is an error, the error wins, because
  # the outcome no longer depends on the unknown inputs. In `&&`, `||` and
  # comprehensions an unknown wins over an error, because a known input could
  # still decide the result.
  @moduledoc false

  alias PB.CEL.Checked

  defstruct entries: MapSet.new()

  @type attribute :: {:var, String.t()} | {:call, String.t(), Checked.expr_id()}
  @type reason :: term
  @type entry :: {attribute, reason}
  @type t :: %__MODULE__{entries: MapSet.t(entry)}

  @doc """
  Builds an unknown with a single entry.
  """
  @spec new(attribute, reason) :: t
  def new(attribute, reason), do: %__MODULE__{entries: MapSet.new([{attribute, reason}])}

  @doc """
  Returns the union of two unknowns.
  """
  @spec merge(t, t) :: t
  def merge(%__MODULE__{entries: left}, %__MODULE__{entries: right}) do
    %__MODULE__{entries: MapSet.union(left, right)}
  end

  @doc """
  Returns the entries in a stable order.
  """
  @spec entries(t) :: [entry]
  def entries(%__MODULE__{entries: entries}), do: Enum.sort(entries)

  @doc """
  Returns the attributes the unknown depends on.
  """
  @spec attributes(t) :: MapSet.t(attribute)
  def attributes(%__MODULE__{entries: entries}), do: MapSet.new(entries, &elem(&1, 0))
end

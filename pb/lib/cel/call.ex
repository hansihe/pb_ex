defmodule CEL.Call do
  @moduledoc false

  @intrinsic_functions MapSet.new([
                         "!_",
                         "-_",
                         "_!=_",
                         "_%_",
                         "_&&_",
                         "_*_",
                         "_+_",
                         "_-_",
                         "_/_",
                         "_<=_",
                         "_<_",
                         "_==_",
                         "_>=_",
                         "_>_",
                         "_?_:_",
                         "_[_]",
                         "_[?_]",
                         "_||_",
                         "_?._",
                         "@in",
                         "@not_strictly_false"
                       ])

  defstruct [:shape, :function, :target, args: []]

  @type shape :: :global | :receiver | :intrinsic | {:namespace, String.t()}

  @type t :: %__MODULE__{
          shape: shape(),
          function: String.t(),
          target: map | nil,
          args: [map]
        }

  @spec classify(map, keyword) :: t()
  def classify(%{function: function} = call, opts \\ []) do
    target = Map.get(call, :target)
    args = Map.get(call, :args, [])

    namespaces = opts |> Keyword.get(:namespaces, []) |> MapSet.new()
    namespace = namespace_target(target, namespaces)

    cond do
      MapSet.member?(@intrinsic_functions, function) ->
        %__MODULE__{shape: :intrinsic, function: function, target: target, args: args}

      match?({:ok, _namespace}, namespace) ->
        {:ok, namespace} = namespace
        %__MODULE__{shape: {:namespace, namespace}, function: function, args: args}

      is_nil(target) ->
        %__MODULE__{shape: :global, function: function, args: args}

      true ->
        %__MODULE__{shape: :receiver, function: function, target: target, args: args}
    end
  end

  @spec intrinsic?(String.t()) :: boolean
  def intrinsic?(function), do: MapSet.member?(@intrinsic_functions, function)

  @spec namespace?(t(), String.t()) :: boolean
  def namespace?(%__MODULE__{shape: {:namespace, namespace}}, namespace), do: true
  def namespace?(%__MODULE__{}, _namespace), do: false

  @spec receiver?(t()) :: boolean
  def receiver?(%__MODULE__{shape: :receiver}), do: true
  def receiver?(%__MODULE__{}), do: false

  @spec reference_name(t()) :: String.t()
  def reference_name(%__MODULE__{shape: {:namespace, namespace}, function: function}) do
    namespace <> "." <> function
  end

  def reference_name(%__MODULE__{function: function}), do: function

  defp namespace_target(%{expr_kind: {:ident_expr, %{name: namespace}}}, namespaces) do
    if MapSet.member?(namespaces, namespace), do: {:ok, namespace}, else: :error
  end

  defp namespace_target(_target, _namespaces), do: :error
end

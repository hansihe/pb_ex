defmodule CEL.Checker.NameResolution do
  @moduledoc false

  alias CEL.Env
  alias CEL.Checker.Types, as: CType
  alias CEL.ProtoType
  alias CEL.Value
  alias CEL.WellKnownTypes

  @type resolved ::
          %{
            required(:kind) => :var,
            required(:name) => String.t(),
            required(:type) => CType.t()
          }
          | %{
              required(:kind) => :local,
              required(:name) => String.t(),
              required(:type) => CType.t()
            }
          | %{
              required(:kind) => :type,
              required(:name) => String.t(),
              required(:type) => CType.t(),
              required(:denotation) => ProtoType.t()
            }
          | %{
              required(:kind) => :enum_value,
              required(:name) => String.t(),
              required(:type) => CType.t(),
              required(:value) => Value.t()
            }

  @spec resolve(map, Env.t(), [%{String.t() => CType.t()}]) :: {:ok, resolved} | :error
  def resolve(expr, %Env{} = env, scopes \\ []) do
    with {:ok, name, absolute?} <- qualified_name(expr) do
      resolve_name(name, env, scopes, absolute?)
    end
  end

  # The type a message literal names: a well-known type's name, or the
  # provider's for a message. An unknown one is reported as written when
  # qualified, otherwise as if in the container.
  @spec resolve_message_name(String.t(), Env.t()) ::
          {:ok, CEL.TypeProvider.name()} | {:error, String.t()}
  def resolve_message_name(name, %Env{} = env) when is_binary(name) do
    candidates = candidates(name, env, false)

    Enum.find_value(candidates, {:error, fallback_message_name(name, candidates)}, fn candidate ->
      if WellKnownTypes.literal_message?(candidate) do
        {:ok, candidate}
      else
        case Env.find_type(env, candidate) do
          {:ok, :message, message} -> {:ok, message}
          _other -> nil
        end
      end
    end)
  end

  @spec resolve_enum_call(CEL.Call.t(), Env.t(), [%{String.t() => CType.t()}]) ::
          {:ok, CEL.TypeProvider.name()} | :error
  def resolve_enum_call(%CEL.Call{shape: :global, function: name}, %Env{} = env, scopes) do
    resolve_enum_name(name, env, scopes, false)
  end

  def resolve_enum_call(
        %CEL.Call{shape: :receiver, target: target, function: function},
        %Env{} = env,
        scopes
      ) do
    with {:ok, prefix, absolute?} <- qualified_name(target) do
      resolve_enum_name(prefix <> "." <> function, env, scopes, absolute?)
    end
  end

  def resolve_enum_call(%CEL.Call{}, %Env{}, _scopes), do: :error

  defp resolve_name(name, env, scopes, false) do
    case local_resolution(name, scopes) do
      {:ok, resolved} -> {:ok, resolved}
      :field_selection -> :error
      :error -> resolve_env_name(name, env, false)
    end
  end

  defp resolve_name(name, env, _scopes, true), do: resolve_env_name(name, env, true)

  defp resolve_env_name(name, env, absolute?) do
    name
    |> candidates(env, absolute?)
    |> Enum.find_value(&resolve_candidate(env, &1))
    |> case do
      nil -> :error
      resolved -> {:ok, resolved}
    end
  end

  defp local_resolution(name, scopes) do
    case String.split(name, ".", trim: true) do
      [local_name] ->
        fetch_local(scopes, local_name)

      [local_name | _fields] ->
        if local_name?(scopes, local_name), do: :field_selection, else: :error

      [] ->
        :error
    end
  end

  defp fetch_local(scopes, name) do
    Enum.find_value(scopes, :error, fn scope ->
      case Map.fetch(scope, name) do
        {:ok, type} -> {:ok, %{kind: :local, name: name, type: type}}
        :error -> nil
      end
    end)
  end

  defp local_name?(scopes, name) do
    Enum.any?(scopes, &Map.has_key?(&1, name))
  end

  # CEL's own type names come first; the provider is never asked about them.
  defp resolve_candidate(env, name) do
    case Env.fetch_var(env, name) do
      {:ok, type} ->
        %{kind: :var, name: name, type: type}

      :error ->
        resolve_type_denotation(name) || resolve_enum_value(env, name) ||
          resolve_provider_type(env, name)
    end
  end

  defp resolve_type_denotation(name) do
    case builtin_denotation(name) do
      {:ok, denotation} ->
        %{
          kind: :type,
          name: name,
          type: CType.type(CType.from_cel(denotation)),
          denotation: denotation
        }

      :error ->
        nil
    end
  end

  defp builtin_denotation(name) do
    case ProtoType.denotation(name) do
      {:ok, denotation} ->
        {:ok, denotation}

      :error ->
        if WellKnownTypes.literal_message?(name),
          do: {:ok, ProtoType.message(name)},
          else: :error
    end
  end

  # `pkg.Enum.VALUE`: the enum is resolved first, so the value's type and
  # value carry the provider's name for it.
  defp resolve_enum_value(env, name) do
    with [_, _ | _] = parts <- String.split(name, "."),
         {value_name, enum_parts} = List.pop_at(parts, -1),
         {:ok, :enum, enum} <- Env.find_type(env, Enum.join(enum_parts, ".")),
         {:ok, number} <- Env.enum_value(env, enum, value_name) do
      %{
        kind: :enum_value,
        name: to_string(enum) <> "." <> value_name,
        type: CType.message(enum),
        value: Value.enum(enum, number)
      }
    else
      _other -> nil
    end
  end

  defp resolve_provider_type(env, name) do
    case Env.find_type(env, name) do
      {:ok, _kind, type} ->
        %{
          kind: :type,
          name: name,
          type: CType.type(CType.message(type)),
          denotation: ProtoType.message(type)
        }

      :error ->
        nil
    end
  end

  defp resolve_enum_name(name, env, scopes, absolute?) do
    with :ok <- local_prefix_available(name, scopes, absolute?) do
      name
      |> candidates(env, absolute?)
      |> Enum.find_value(fn candidate ->
        case Env.find_type(env, candidate) do
          {:ok, :enum, enum} -> enum
          _other -> nil
        end
      end)
      |> case do
        nil -> :error
        enum -> {:ok, enum}
      end
    end
  end

  defp local_prefix_available(_name, _scopes, true), do: :ok

  defp local_prefix_available(name, scopes, false) do
    root = name |> String.split(".", parts: 2) |> hd()

    if local_name?(scopes, root), do: :error, else: :ok
  end

  # An abbreviation replaces the container search: its expansion is the only
  # candidate, even for a name with a leading dot, as in cel-go and cel-cpp.
  defp candidates("." <> name, env, _absolute?), do: candidates(name, env, true)

  defp candidates(name, %Env{} = env, absolute?) do
    case expand_abbreviation(name, env) do
      {:ok, expanded} -> [expanded]
      :error when absolute? -> [name]
      :error -> container_candidates(name, env.container)
    end
  end

  defp expand_abbreviation(name, %Env{abbreviations: abbreviations}) do
    [first | rest] = String.split(name, ".", parts: 2)

    case Map.fetch(abbreviations, first) do
      {:ok, qualified} -> {:ok, Enum.join([qualified | rest], ".")}
      :error -> :error
    end
  end

  defp container_candidates(name, container) when container in ["", nil], do: [name]

  defp container_candidates(name, container) do
    parts = String.split(container, ".", trim: true)

    prefixed =
      for size <- length(parts)..1//-1 do
        parts
        |> Enum.take(size)
        |> Enum.join(".")
        |> then(&(&1 <> "." <> name))
      end

    prefixed ++ [name]
  end

  # An unknown message is reported as written when qualified, otherwise as if
  # in the container.
  defp fallback_message_name(name, [first | _] = candidates) do
    if String.contains?(name, "."), do: List.last(candidates), else: first
  end

  defp qualified_name(%{expr_kind: {:ident_expr, %{name: "." <> name}}}), do: {:ok, name, true}
  defp qualified_name(%{expr_kind: {:ident_expr, %{name: name}}}), do: {:ok, name, false}

  defp qualified_name(%{expr_kind: {:select_expr, %{operand: operand, field: field}}}) do
    with {:ok, prefix, absolute?} <- qualified_name(operand) do
      {:ok, prefix <> "." <> field, absolute?}
    end
  end

  defp qualified_name(_expr), do: :error
end

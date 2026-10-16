defmodule PB.TextFormat.FieldNames do
  @moduledoc false

  # How fields are named in text format, shared by the decoder and encoder.
  #
  # Regular fields use their name and extensions their full name in brackets.
  # A group-like field — delimited, named after its lowercased message type,
  # with the type nested in the same message (so declared in the same file
  # and scope, as C++ `IsGroupLike` requires) — is printed with the type's
  # name, and the parser accepts either spelling.

  @doc "The name a field is printed with inside `message_name`."
  @spec text_name(atom, map) :: String.t()
  def text_name(_message_name, %{kind: :extension, name: name}), do: "[#{name}]"

  def text_name(message_name, field) do
    if group_like?(message_name, field),
      do: type_name(field),
      else: Atom.to_string(field.name)
  end

  @doc "Whether `field` of `message_name` is group-like."
  @spec group_like?(atom, map) :: boolean
  def group_like?(message_name, field) do
    if field.encoding == :delimited do
      {scope, type} = split_name(field.type_name)

      Atom.to_string(field.name) == String.downcase(type, :ascii) and
        scope == Atom.to_string(message_name)
    else
      false
    end
  end

  @doc "The simple (unqualified) name of a message-typed field's type."
  @spec type_name(map) :: String.t()
  def type_name(field), do: field.type_name |> split_name() |> elem(1)

  defp split_name(full_name) do
    full_name = Atom.to_string(full_name)

    case :binary.matches(full_name, ".") do
      [] ->
        {"", full_name}

      matches ->
        {dot, 1} = List.last(matches)

        {binary_part(full_name, 0, dot),
         binary_part(full_name, dot + 1, byte_size(full_name) - dot - 1)}
    end
  end
end

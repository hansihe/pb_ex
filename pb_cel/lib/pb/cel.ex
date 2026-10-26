defmodule PB.CEL do
  @moduledoc """
  CEL expressions over protobuf messages: `types/1` makes a PB schema's
  messages and enums the types of a `CEL.Env`.

      env =
        CEL.Env.build(
          types: PB.CEL.types(MyApp.Schema),
          container: "my.pkg",
          vars: [user: {:message, "my.pkg.User"}]
        )

      CEL.eval("user.age >= 18 && user.role == Role.ADMIN", %{user: user}, env)

  Message and enum types are named by PB's atoms, so a message value is
  `{:message, :"my.pkg.User", fields}` and an enum value
  `{:enum, :"my.pkg.Role", 2}`. A message variable binds to the message as
  `PB.decode/4` returns it, and an enum variable to a value's name as an
  atom or its number. The well-known types are the CEL types they stand for:
  a `google.protobuf.Timestamp` field reads as a timestamp, an
  `Int64Value` one as an int or `null`.
  """

  @doc """
  The `CEL.TypeProvider` for `schema`: a module that `use PB.Schema`, or a
  compiled schema from `PB.compile/2`.

  A module is kept as it is and its schema read when needed, so environments
  and programs stay small.
  """
  @spec types(PB.schema() | module) :: CEL.TypeProvider.t()
  def types(schema) when is_atom(schema) do
    unless Code.ensure_loaded?(schema) and function_exported?(schema, :__pb_schema__, 0) do
      raise ArgumentError, "expected a PB schema module, got: #{inspect(schema)}"
    end

    {PB.CEL.Types, schema}
  end

  def types(%{messages: messages, enums: enums} = schema)
      when is_map(messages) and is_map(enums),
      do: {PB.CEL.Types, schema}

  def types(schema),
    do: raise(ArgumentError, "expected a PB schema or schema module, got: #{inspect(schema)}")
end

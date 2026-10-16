defmodule PB.Validate.Compiler do
  @moduledoc false

  # Compiles protovalidate descriptor options into schema validation metadata.
  #
  # This compiler runs on the prepared schema, whose descriptor options are kept
  # and materialized; `PB.Validate.Compiler.Options` materializes the rules of
  # a descriptor set that does not define buf.validate itself. It annotates message, field, oneof, and extension entries
  # with plain validation data under `PB.Validate`, in the places
  # `PB.Schema.Plugin` lets a plugin write to: `:fields_by_name`,
  # `:extensions_by_name`, and `:oneofs`, not the runtime index copies such as
  # `:fields_by_number` or `:map_entry`, which `PB.Validate` does not read.
  #
  # The validation compiler depends on schema semantic facts that are fixed before
  # annotation, especially field type, presence, cardinality, map key/value shape,
  # and enum/message type names. Missing referenced messages, enums, or extension
  # definitions are treated as schema/compiler errors, not soft fallbacks.
  #
  # This module is the orchestrator: it walks the schema and delegates the actual
  # rule compilation to the `PB.Validate.Compiler.*` modules, threading a single
  # `PB.Validate.Compiler.Context` (the user schema plus the once-built merged
  # standard-rule schema) through the field compiler.

  alias PB.Validate.Compiler.CEL
  alias PB.Validate.Compiler.Context
  alias PB.Validate.Compiler.Extensions
  alias PB.Validate.Compiler.Fields
  alias PB.Validate.Compiler.Options

  @doc """
  Annotates a prepared schema with precompiled protovalidate validation ops.
  """
  @spec annotate(PB.schema()) :: PB.schema()
  def annotate(schema) when is_map(schema) do
    schema =
      schema
      |> Options.materialize()
      |> annotate_schema_extensions()
      |> annotate_message_extension_definitions()

    ctx = Context.new(schema)

    Map.update!(schema, :messages, fn messages ->
      Map.new(messages, fn {fqn, message} ->
        {fqn, annotate_message(ctx, fqn, message)}
      end)
    end)
  end

  defp annotate_message_extension_definitions(schema) do
    Map.update!(schema, :messages, fn messages ->
      Map.new(messages, fn {fqn, message} ->
        {fqn, annotate_message_extensions(message)}
      end)
    end)
  end

  defp annotate_message(ctx, fqn, %{fields_by_name: fields_by_name} = message) do
    message =
      message
      |> Extensions.add_structural_validation(Extensions.message_structural_rules(message, fqn))
      |> CEL.add_user_cel_validation(
        Extensions.message_cel_rules(message),
        ctx.user_schema,
        Atom.to_string(fqn),
        {:message, fqn},
        :message_cel
      )
      |> CEL.add_user_cel_validation(
        Extensions.message_cel_expression_rules(message),
        ctx.user_schema,
        Atom.to_string(fqn),
        {:message, fqn},
        :message_cel,
        :message_cel_expression
      )

    fields_by_name =
      Map.new(fields_by_name, fn {name, field} ->
        {name, Fields.annotate(ctx, fqn, field)}
      end)

    message
    |> Map.put(:fields_by_name, fields_by_name)
    |> annotate_message_extensions()
    |> Map.update!(:oneofs, fn oneofs ->
      Map.new(oneofs, fn {index, oneof} -> {index, annotate_oneof(oneof)} end)
    end)
  end

  defp annotate_message(_ctx, _fqn, message), do: message

  defp annotate_oneof(oneof) do
    Extensions.add_structural_validation(oneof, Extensions.oneof_structural_rules(oneof))
  end

  defp annotate_schema_extensions(schema) do
    Map.update!(schema, :extensions_by_name, &Extensions.annotate_extensions/1)
  end

  defp annotate_message_extensions(message) do
    extensions_by_name = Extensions.annotate_extensions(message.extensions_by_name)
    Map.put(message, :extensions_by_name, extensions_by_name)
  end
end

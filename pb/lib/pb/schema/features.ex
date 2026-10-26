defmodule PB.Schema.Features do
  @moduledoc false

  # Resolves protobuf source syntax, editions, and feature options into PB's
  # compiled schema semantics.
  #
  # Feature values are kept on compiled fields under `:features` so the protobuf
  # language model remains visible. Runtime behavior should use the normalized
  # fields instead:
  #
  #   * `:cardinality` is `:singular`, `:repeated`, or `:map`.
  #   * `:presence` is `:implicit`, `:explicit`, `:required`, `:oneof`, or
  #     `:none` for repeated/map fields.
  #   * `:encoding` is `:scalar`, `:expanded`, `:packed`, `:length_prefixed`, or
  #     `:delimited`.
  #   * `:source` records descriptor provenance such as raw `:type`, `:label`,
  #     `:proto3_optional`, and synthetic oneof indexes. It is not a runtime
  #     behavior input.

  alias PB.Wire

  @unknown_values MapSet.new([
                    0,
                    :FIELD_PRESENCE_UNKNOWN,
                    :ENUM_TYPE_UNKNOWN,
                    :REPEATED_FIELD_ENCODING_UNKNOWN,
                    :MESSAGE_ENCODING_UNKNOWN,
                    :UTF8_VALIDATION_UNKNOWN,
                    :JSON_FORMAT_UNKNOWN,
                    :DEFAULT_SYMBOL_VISIBILITY_UNKNOWN,
                    :ENFORCE_NAMING_STYLE_UNKNOWN
                  ])

  @file_feature_keys [
    :field_presence,
    :enum_type,
    :repeated_field_encoding,
    :message_encoding,
    :utf8_validation,
    :json_format,
    :default_symbol_visibility,
    :enforce_naming_style
  ]

  @message_feature_keys [
    :json_format,
    :enforce_naming_style
  ]

  @field_feature_keys [
    :field_presence,
    :repeated_field_encoding,
    :message_encoding,
    :utf8_validation,
    :enforce_naming_style
  ]

  @enum_feature_keys [
    :enum_type,
    :json_format,
    :enforce_naming_style
  ]

  def file_context(syntax, edition, options) do
    edition = normalize_edition(edition)

    syntax
    |> defaults(edition)
    |> merge_options(options, @file_feature_keys)
  end

  def message_context(parent, options) do
    merge_options(parent, options, @message_feature_keys)
  end

  def field_features(parent, field) do
    parent
    |> Map.take(@field_feature_keys)
    |> merge_options(field[:options], @field_feature_keys)
    |> apply_legacy_field_flags(field)
  end

  def field_semantics(parent, field) do
    features = field_features(parent, field)
    cardinality = descriptor_cardinality(field)
    presence = resolved_presence(cardinality, field, features)
    encoding = resolved_encoding(cardinality, field, features)

    %{
      features: features,
      cardinality: cardinality,
      presence: presence,
      encoding: encoding,
      source: field_source(field)
    }
  end

  def runtime_type(:TYPE_GROUP), do: :TYPE_MESSAGE
  def runtime_type(type), do: type

  def wire_type(type, :delimited) when type in [:TYPE_MESSAGE, :TYPE_GROUP], do: 3
  def wire_type(type, _encoding), do: Wire.wire_type(runtime_type(type))

  def enum_features(parent, options) do
    parent
    |> Map.take(@enum_feature_keys)
    |> merge_options(options, @enum_feature_keys)
  end

  def has_presence?(field) do
    field.presence in [:explicit, :required, :oneof]
  end

  def implicit_presence?(field), do: field.presence == :implicit

  def required?(field), do: field.presence == :required

  def oneof?(field), do: field.presence == :oneof

  def repeated?(field), do: field.cardinality in [:repeated, :map]

  def map?(field), do: field.cardinality == :map

  def packed?(field), do: field.encoding == :packed

  def message_encoding(field) do
    case field.encoding do
      :delimited -> :DELIMITED
      _ -> :LENGTH_PREFIXED
    end
  end

  def verify_utf8?(%{features: %{utf8_validation: :VERIFY}}), do: true
  def verify_utf8?(_field), do: false

  def closed_enum?(nil), do: false

  def closed_enum?(enum) do
    get_in(enum, [:features, :enum_type]) == :CLOSED
  end

  def source(syntax, edition) do
    %{syntax: syntax, edition: normalize_edition(edition)}
  end

  defp descriptor_cardinality(%{label: :LABEL_REPEATED}), do: :repeated
  defp descriptor_cardinality(_field), do: :singular

  defp resolved_presence(cardinality, _field, _features) when cardinality in [:repeated, :map],
    do: :none

  defp resolved_presence(:singular, field, features) do
    cond do
      real_oneof?(field) ->
        :oneof

      features.field_presence == :LEGACY_REQUIRED ->
        :required

      extension?(field) ->
        :explicit

      message_type?(field) ->
        :explicit

      features.field_presence == :EXPLICIT ->
        :explicit

      true ->
        :implicit
    end
  end

  defp resolved_encoding(_cardinality, %{type: :TYPE_GROUP}, _features), do: :delimited

  defp resolved_encoding(_cardinality, %{type: :TYPE_MESSAGE}, features) do
    case features.message_encoding do
      :DELIMITED -> :delimited
      _ -> :length_prefixed
    end
  end

  defp resolved_encoding(:repeated, field, features) do
    cond do
      Wire.packable_type?(field.type) and features.repeated_field_encoding == :PACKED ->
        :packed

      true ->
        :expanded
    end
  end

  defp resolved_encoding(_cardinality, _field, _features), do: :scalar

  defp field_source(field) do
    %{
      type: field[:type],
      label: field[:label] || :LABEL_OPTIONAL
    }
    |> maybe_put(:oneof_index, field[:oneof_index])
    |> maybe_put(:proto3_optional, field[:proto3_optional])
    |> maybe_put(:packed, get_in(field, [:options, :packed]))
    |> maybe_put(:extendee, field[:extendee])
  end

  defp defaults(syntax, edition) do
    case source_semantics(syntax, edition) do
      :proto2 ->
        %{
          field_presence: :EXPLICIT,
          enum_type: :CLOSED,
          repeated_field_encoding: :EXPANDED,
          message_encoding: :LENGTH_PREFIXED,
          utf8_validation: :NONE,
          json_format: :LEGACY_BEST_EFFORT
        }

      :proto3 ->
        %{
          field_presence: :IMPLICIT,
          enum_type: :OPEN,
          repeated_field_encoding: :PACKED,
          message_encoding: :LENGTH_PREFIXED,
          utf8_validation: :VERIFY,
          json_format: :ALLOW
        }

      :edition ->
        %{
          field_presence: :EXPLICIT,
          enum_type: :OPEN,
          repeated_field_encoding: :PACKED,
          message_encoding: :LENGTH_PREFIXED,
          utf8_validation: :VERIFY,
          json_format: :ALLOW,
          default_symbol_visibility: default_symbol_visibility(edition),
          enforce_naming_style: enforce_naming_style(edition)
        }
    end
  end

  defp source_semantics(_syntax, edition) when edition in [:EDITION_PROTO2, :PROTO2], do: :proto2
  defp source_semantics(_syntax, edition) when edition in [:EDITION_PROTO3, :PROTO3], do: :proto3

  defp source_semantics(_syntax, edition)
       when edition in [:EDITION_2023, :EDITION_2024, :EDITION_UNSTABLE],
       do: :edition

  defp source_semantics(syntax, edition) do
    if unsupported_edition?(edition) do
      raise PB.SchemaError, kind: :unsupported_edition, type_name: edition
    else
      if syntax in [:proto3, "proto3"], do: :proto3, else: :proto2
    end
  end

  # An edition that is explicitly set (any `EDITION_*` enum value, or a raw
  # positive enum number) but not handled above must not be silently downgraded
  # to proto2 semantics. `EDITION_UNKNOWN`/`EDITION_LEGACY` and the non-edition
  # syntax atoms still resolve normally.
  defp unsupported_edition?(edition) when is_atom(edition) and not is_nil(edition) do
    case Atom.to_string(edition) do
      "EDITION_UNKNOWN" -> false
      "EDITION_LEGACY" -> false
      "EDITION_" <> _ -> true
      _ -> false
    end
  end

  defp unsupported_edition?(edition) when is_integer(edition), do: edition > 0
  defp unsupported_edition?(_edition), do: false

  defp default_symbol_visibility(:EDITION_2024), do: :EXPORT_TOP_LEVEL
  defp default_symbol_visibility(_edition), do: :EXPORT_ALL

  defp enforce_naming_style(:EDITION_2024), do: :STYLE2024
  defp enforce_naming_style(_edition), do: :STYLE_LEGACY

  defp merge_options(features, nil, _allowed), do: features

  defp merge_options(features, options, allowed) do
    option_features =
      options
      |> option_features()
      |> Map.take(allowed)
      |> reject_unknown_values()

    Map.merge(features, option_features)
  end

  defp option_features(%{features: features}) when is_map(features), do: features
  defp option_features(_options), do: %{}

  defp reject_unknown_values(features) do
    Map.reject(features, fn {_key, value} -> MapSet.member?(@unknown_values, value) end)
  end

  defp apply_legacy_field_flags(features, field) do
    features
    |> maybe_put_required(field)
    |> maybe_put_proto3_optional(field)
    |> maybe_put_packed(field)
    |> maybe_put_group_encoding(field)
  end

  defp maybe_put_required(features, %{label: :LABEL_REQUIRED}) do
    Map.put(features, :field_presence, :LEGACY_REQUIRED)
  end

  defp maybe_put_required(features, _field), do: features

  defp maybe_put_proto3_optional(features, %{proto3_optional: true}) do
    Map.put(features, :field_presence, :EXPLICIT)
  end

  defp maybe_put_proto3_optional(features, _field), do: features

  defp maybe_put_packed(features, %{label: :LABEL_REPEATED, type: type} = field) do
    if Wire.packable_type?(type) do
      case get_in(field, [:options, :packed]) do
        true -> Map.put(features, :repeated_field_encoding, :PACKED)
        false -> Map.put(features, :repeated_field_encoding, :EXPANDED)
        _ -> features
      end
    else
      features
    end
  end

  defp maybe_put_packed(features, _field), do: features

  defp maybe_put_group_encoding(features, %{type: :TYPE_GROUP}) do
    Map.put(features, :message_encoding, :DELIMITED)
  end

  defp maybe_put_group_encoding(features, _field), do: features

  defp real_oneof?(field) do
    Map.has_key?(field, :oneof_index) and not Map.get(field, :proto3_optional, false)
  end

  defp extension?(field), do: Map.has_key?(field, :extendee)

  defp message_type?(%{type: type}), do: type in [:TYPE_MESSAGE, :TYPE_GROUP]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_edition(nil), do: nil
  defp normalize_edition(:"2023"), do: :EDITION_2023
  defp normalize_edition(:"2024"), do: :EDITION_2024
  defp normalize_edition(edition), do: edition
end

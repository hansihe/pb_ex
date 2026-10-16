defmodule PB.Validate.CELExtensions.Strings do
  @moduledoc false

  alias CEL.Value
  import Bitwise, only: [<<<: 2]

  @type result :: {:ok, Value.t()} | {:error, String.t()}

  @spec is_hostname([Value.t()]) :: result
  def is_hostname([{:string, value}]), do: bool(valid_hostname?(value))
  def is_hostname(_values), do: no_such_overload()

  @spec is_email([Value.t()]) :: result
  def is_email([{:string, value}]), do: bool(valid_email?(value))
  def is_email(_values), do: no_such_overload()

  @spec is_host_and_port([Value.t()]) :: result
  def is_host_and_port([{:string, value}, {:bool, port_required}]) do
    bool(valid_host_and_port?(value, port_required))
  end

  def is_host_and_port(_values), do: no_such_overload()

  @spec is_ip([Value.t()]) :: result
  def is_ip([{:string, value}]), do: bool(valid_ip?(value, 0, allow_zone?: true))

  def is_ip([{:string, value}, {:int, version}]),
    do: bool(valid_ip?(value, version, allow_zone?: true))

  def is_ip(_values), do: no_such_overload()

  @spec is_ip_prefix([Value.t()]) :: result
  def is_ip_prefix([{:string, value}]), do: bool(valid_ip_prefix?(value, 0, false))

  def is_ip_prefix([{:string, value}, {:int, version}]) do
    bool(valid_ip_prefix?(value, version, false))
  end

  def is_ip_prefix([{:string, value}, {:bool, strict}]) do
    bool(valid_ip_prefix?(value, 0, strict))
  end

  def is_ip_prefix([{:string, value}, {:int, version}, {:bool, strict}]) do
    bool(valid_ip_prefix?(value, version, strict))
  end

  def is_ip_prefix(_values), do: no_such_overload()

  @spec is_uri([Value.t()]) :: result
  def is_uri([{:string, value}]), do: bool(valid_uri?(value))
  def is_uri(_values), do: no_such_overload()

  @spec is_uri_ref([Value.t()]) :: result
  def is_uri_ref([{:string, value}]), do: bool(valid_uri_ref?(value))
  def is_uri_ref(_values), do: no_such_overload()

  defp valid_email?(value) do
    case String.split(value, "@") do
      [local, domain] ->
        valid_email_local?(local) and valid_email_domain?(domain)

      _other ->
        false
    end
  end

  defp valid_email_local?(""), do: false

  defp valid_email_local?(local) do
    local
    |> :binary.bin_to_list()
    |> Enum.all?(&email_local_char?/1)
  end

  defp valid_email_domain?(""), do: false

  defp valid_email_domain?(domain) do
    not String.ends_with?(domain, ".") and
      domain
      |> String.split(".")
      |> Enum.all?(&valid_email_domain_label?/1)
  end

  defp valid_email_domain_label?(label) do
    byte_size(label) in 1..63 and
      Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z/, label)
  end

  defp valid_host_and_port?(value, port_required) do
    case parse_host_and_port(value) do
      {:ok, _host_kind, _host, nil} when port_required ->
        false

      {:ok, _host_kind, _host, nil} ->
        true

      {:ok, _host_kind, _host, port} ->
        valid_port?(port)

      :error ->
        false
    end
  end

  defp parse_host_and_port(""), do: :error

  defp parse_host_and_port("[" <> rest) do
    case String.split(rest, "]") do
      [_only] ->
        :error

      parts ->
        {host_parts, after_parts} = Enum.split(parts, length(parts) - 1)
        host = Enum.join(host_parts, "]")
        after_bracket = List.first(after_parts)

        cond do
          not valid_ip?(host, 6, allow_zone?: true) ->
            :error

          after_bracket == "" ->
            {:ok, :ipv6, host, nil}

          match?(":" <> _port, after_bracket) ->
            ":" <> port = after_bracket
            {:ok, :ipv6, host, port}

          true ->
            :error
        end
    end
  end

  defp parse_host_and_port(value) do
    case String.split(value, ":") do
      [host] ->
        parse_host(host, nil)

      [host, port] ->
        parse_host(host, port)

      _parts ->
        :error
    end
  end

  defp parse_host(host, port) do
    cond do
      valid_ip?(host, 4, allow_zone?: false) ->
        {:ok, :ipv4, host, port}

      valid_hostname?(host) ->
        {:ok, :hostname, host, port}

      true ->
        :error
    end
  end

  defp valid_port?(""), do: false
  defp valid_port?("0"), do: true

  defp valid_port?(port) do
    digits?(port) and not String.starts_with?(port, "0") and
      case Integer.parse(port) do
        {value, ""} -> value <= 65_535
        _other -> false
      end
  end

  defp valid_hostname?(""), do: false

  defp valid_hostname?(hostname) do
    normalized = String.replace_suffix(hostname, ".", "")

    hostname_length_ok?(hostname) and normalized != "" and
      normalized
      |> String.split(".")
      |> valid_hostname_labels?()
  end

  defp hostname_length_ok?(hostname) do
    limit = if String.ends_with?(hostname, "."), do: 254, else: 253
    byte_size(hostname) <= limit
  end

  defp valid_hostname_labels?(labels) do
    Enum.all?(labels, &valid_hostname_label?/1) and not digits?(List.last(labels))
  end

  defp valid_hostname_label?(label) do
    byte_size(label) in 1..63 and
      Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z/, label)
  end

  defp valid_uri?(""), do: false

  defp valid_uri?(value) do
    with {:candidate, scheme, rest} <- uri_scheme_candidate(value),
         true <- valid_scheme?(scheme),
         true <- valid_uri_after_scheme?(rest) do
      true
    else
      _other -> false
    end
  end

  defp valid_uri_ref?(value) do
    case uri_scheme_candidate(value) do
      {:candidate, scheme, rest} ->
        valid_scheme?(scheme) and valid_uri_after_scheme?(rest)

      :none ->
        valid_relative_ref?(value)
    end
  end

  defp uri_scheme_candidate(value) do
    case :binary.match(value, ":") do
      :nomatch ->
        :none

      {index, 1} ->
        if delimiter_before?(value, index, [?/, ??, ?#]) do
          :none
        else
          scheme = binary_part(value, 0, index)
          rest = binary_part(value, index + 1, byte_size(value) - index - 1)
          {:candidate, scheme, rest}
        end
    end
  end

  defp delimiter_before?(value, index, delimiters) do
    prefix = binary_part(value, 0, index)

    Enum.any?(delimiters, fn delimiter ->
      :binary.match(prefix, <<delimiter>>) != :nomatch
    end)
  end

  defp valid_scheme?(""), do: false

  defp valid_scheme?(<<first, rest::binary>>) do
    ascii_alpha?(first) and
      rest
      |> :binary.bin_to_list()
      |> Enum.all?(&scheme_char?/1)
  end

  defp valid_uri_after_scheme?(rest) do
    {main, query, fragment} = split_uri_tail(rest)

    valid_optional_query_fragment?(query, fragment) and
      if String.starts_with?(main, "//") do
        main
        |> binary_part(2, byte_size(main) - 2)
        |> valid_authority_and_path?()
      else
        valid_path?(main)
      end
  end

  defp valid_relative_ref?(value) do
    {main, query, fragment} = split_uri_tail(value)

    valid_optional_query_fragment?(query, fragment) and
      if String.starts_with?(main, "//") do
        main
        |> binary_part(2, byte_size(main) - 2)
        |> valid_authority_and_path?()
      else
        valid_path?(main)
      end
  end

  defp split_uri_tail(value) do
    {before_fragment, fragment} = split_once(value, "#")
    {main, query} = split_once(before_fragment, "?")
    {main, query, fragment}
  end

  defp split_once(value, delimiter) do
    case :binary.match(value, delimiter) do
      :nomatch ->
        {value, nil}

      {index, size} ->
        before = binary_part(value, 0, index)
        after_delimiter = binary_part(value, index + size, byte_size(value) - index - size)
        {before, after_delimiter}
    end
  end

  defp valid_optional_query_fragment?(query, fragment) do
    (is_nil(query) or valid_query_fragment?(query)) and
      (is_nil(fragment) or valid_query_fragment?(fragment))
  end

  defp valid_authority_and_path?(value) do
    {authority, path} = split_authority_path(value)
    valid_authority?(authority) and valid_path?(path)
  end

  defp split_authority_path(value) do
    case :binary.match(value, "/") do
      :nomatch ->
        {value, ""}

      {index, _size} ->
        authority = binary_part(value, 0, index)
        path = binary_part(value, index, byte_size(value) - index)
        {authority, path}
    end
  end

  defp valid_authority?(authority) do
    case String.split(authority, "@") do
      [host_port] ->
        valid_host_port_authority?(host_port)

      [userinfo, host_port] ->
        valid_encoded?(userinfo, &userinfo_char?/1) and valid_host_port_authority?(host_port)

      _other ->
        false
    end
  end

  defp valid_host_port_authority?("[" <> rest) do
    case :binary.match(rest, "]") do
      :nomatch ->
        false

      {index, 1} ->
        literal = binary_part(rest, 0, index)
        suffix = binary_part(rest, index + 1, byte_size(rest) - index - 1)
        valid_ip_literal?(literal) and valid_uri_port_suffix?(suffix)
    end
  end

  defp valid_host_port_authority?(host_port) do
    cond do
      String.contains?(host_port, ["[", "]"]) ->
        false

      String.contains?(host_port, ":") ->
        case String.split(host_port, ":") do
          [host, port] -> valid_reg_name?(host) and valid_uri_port?(port)
          _other -> false
        end

      true ->
        valid_reg_name?(host_port)
    end
  end

  defp valid_uri_port_suffix?(""), do: true

  defp valid_uri_port_suffix?(":" <> port), do: valid_uri_port?(port)

  defp valid_uri_port_suffix?(_suffix), do: false

  defp valid_uri_port?(""), do: true
  defp valid_uri_port?(port), do: digits?(port)

  defp valid_reg_name?(host) do
    valid_encoded?(host, &reg_name_char?/1, utf8?: true)
  end

  defp valid_ip_literal?(literal), do: valid_ipv6_literal?(literal) or valid_ip_future?(literal)

  defp valid_ipv6_literal?(literal) do
    case String.split(literal, "%25", parts: 2) do
      [ip] ->
        valid_ip?(ip, 6, allow_zone?: false)

      [ip, zone] ->
        zone != "" and valid_ip?(ip, 6, allow_zone?: false) and
          valid_encoded?(zone, &zone_id_char?/1, utf8?: true)
    end
  end

  defp valid_ip_future?(<<"v", rest::binary>>), do: valid_ip_future_tail?(rest)
  defp valid_ip_future?(<<"V", rest::binary>>), do: valid_ip_future_tail?(rest)
  defp valid_ip_future?(_literal), do: false

  defp valid_ip_future_tail?(rest) do
    case split_once(rest, ".") do
      {version, address} when not is_nil(address) ->
        version != "" and address != "" and
          version
          |> :binary.bin_to_list()
          |> Enum.all?(&hex?/1) and
          address
          |> :binary.bin_to_list()
          |> Enum.all?(&ip_future_char?/1)

      _other ->
        false
    end
  end

  defp valid_path?(path), do: valid_encoded?(path, &path_char?/1)
  defp valid_query_fragment?(value), do: valid_encoded?(value, &query_fragment_char?/1)

  defp valid_encoded?(value, char_fun, opts \\ []) do
    case encoded_bytes(value, char_fun, []) do
      {:ok, bytes} ->
        not Keyword.get(opts, :utf8?, false) or String.valid?(IO.iodata_to_binary(bytes))

      :error ->
        false
    end
  end

  defp encoded_bytes("", _char_fun, acc), do: {:ok, Enum.reverse(acc)}

  defp encoded_bytes(<<?%, high, low, rest::binary>>, char_fun, acc) do
    if hex?(high) and hex?(low) do
      encoded_bytes(rest, char_fun, [hex_value(high) * 16 + hex_value(low) | acc])
    else
      :error
    end
  end

  defp encoded_bytes(<<?%, _rest::binary>>, _char_fun, _acc), do: :error

  defp encoded_bytes(<<char, rest::binary>>, char_fun, acc) do
    if char_fun.(char) do
      encoded_bytes(rest, char_fun, [char | acc])
    else
      :error
    end
  end

  defp valid_ip_prefix?(value, version, strict?) when version in [0, 4, 6] do
    with {:ok, address, prefix_length} <- parse_ip_prefix(value),
         true <- ip_version(address) == version or version == 0,
         true <- valid_prefix_length?(address, prefix_length) do
      not strict? or network_address?(address, prefix_length)
    else
      _other -> false
    end
  end

  defp valid_ip_prefix?(_value, _version, _strict?), do: false

  defp parse_ip_prefix(value) do
    case String.split(value, "/") do
      [ip, prefix] ->
        with {:ok, prefix_length} <- parse_prefix_length(prefix),
             {:ok, address} <- parse_ip(ip, allow_zone?: false) do
          {:ok, address, prefix_length}
        end

      _other ->
        :error
    end
  end

  defp parse_prefix_length(""), do: :error
  defp parse_prefix_length("0"), do: {:ok, 0}

  defp parse_prefix_length(prefix) do
    if digits?(prefix) and not String.starts_with?(prefix, "0") do
      case Integer.parse(prefix) do
        {value, ""} -> {:ok, value}
        _other -> :error
      end
    else
      :error
    end
  end

  defp valid_prefix_length?({_, _, _, _}, prefix_length), do: prefix_length in 0..32
  defp valid_prefix_length?({_, _, _, _, _, _, _, _}, prefix_length), do: prefix_length in 0..128

  defp network_address?(address, prefix_length) do
    bits = address_bits(address)
    host_bits = bits - prefix_length

    host_bits == 0 or Bitwise.band(address_integer(address), (1 <<< host_bits) - 1) == 0
  end

  defp valid_ip?(value, version, opts) when version in [0, 4, 6] do
    case parse_ip(value, opts) do
      {:ok, address} -> ip_version(address) == version or version == 0
      :error -> false
    end
  end

  defp valid_ip?(_value, _version, _opts), do: false

  defp parse_ip(value, opts) do
    allow_zone? = Keyword.get(opts, :allow_zone?, false)

    with {:ok, base} <- split_ip_zone(value, allow_zone?) do
      case :inet.parse_strict_address(String.to_charlist(base)) do
        {:ok, address} -> {:ok, address}
        {:error, _reason} -> :error
      end
    end
  end

  defp split_ip_zone(value, false) do
    if String.contains?(value, "%"), do: :error, else: {:ok, value}
  end

  defp split_ip_zone(value, true) do
    case String.split(value, "%", parts: 2) do
      [base] ->
        {:ok, base}

      [base, zone] ->
        if String.contains?(base, ":") and zone != "" and not String.contains?(zone, <<0>>) do
          {:ok, base}
        else
          :error
        end
    end
  end

  defp ip_version({_, _, _, _}), do: 4
  defp ip_version({_, _, _, _, _, _, _, _}), do: 6

  defp address_bits({_, _, _, _}), do: 32
  defp address_bits({_, _, _, _, _, _, _, _}), do: 128

  defp address_integer({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d

  defp address_integer({a, b, c, d, e, f, g, h}) do
    Enum.reduce([a, b, c, d, e, f, g, h], 0, fn part, acc -> (acc <<< 16) + part end)
  end

  defp email_local_char?(char),
    do: ascii_alnum?(char) or char in ~c"!#$%&'*+-/=?^_`{|}~."

  defp scheme_char?(char), do: ascii_alnum?(char) or char in [?+, ?-, ?.]
  defp userinfo_char?(char), do: unreserved?(char) or sub_delim?(char) or char == ?:
  defp reg_name_char?(char), do: unreserved?(char) or sub_delim?(char)
  defp zone_id_char?(char), do: unreserved?(char)
  defp path_char?(char), do: unreserved?(char) or sub_delim?(char) or char in [?:, ?@, ?/]

  defp query_fragment_char?(char) do
    path_char?(char) or char == ??
  end

  defp ip_future_char?(char), do: unreserved?(char) or sub_delim?(char) or char == ?:
  defp unreserved?(char), do: ascii_alnum?(char) or char in [?-, ?., ?_, ?~]

  defp sub_delim?(char),
    do: char in [?!, ?$, ?&, ?', ?(, ?), ?*, ?+, ?,, ?;, ?=]

  defp ascii_alpha?(char), do: char in ?A..?Z or char in ?a..?z
  defp ascii_alnum?(char), do: ascii_alpha?(char) or char in ?0..?9
  defp hex?(char), do: char in ?0..?9 or char in ?A..?F or char in ?a..?f

  defp hex_value(char) when char in ?0..?9, do: char - ?0
  defp hex_value(char) when char in ?A..?F, do: char - ?A + 10
  defp hex_value(char) when char in ?a..?f, do: char - ?a + 10

  defp digits?(value), do: Regex.match?(~r/\A[0-9]+\z/, value)

  defp bool(value), do: {:ok, Value.bool(value)}
  defp no_such_overload, do: {:error, "no such overload"}
end

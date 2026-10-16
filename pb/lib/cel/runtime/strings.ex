defmodule CEL.Runtime.Strings do
  @moduledoc false

  alias CEL.Regexes
  alias CEL.Runtime.Strings.Format
  alias CEL.Value

  @type result :: {:ok, Value.t()} | {:error, String.t()}

  @spec starts_with([Value.t()]) :: result
  def starts_with([{:string, string}, {:string, arg}]) do
    {:ok, Value.bool(String.starts_with?(string, arg))}
  end

  def starts_with([{:bytes, bytes}, {:bytes, arg}]) do
    {:ok, Value.bool(binary_starts_with?(bytes, arg))}
  end

  def starts_with(_values), do: no_such_overload()

  @spec ends_with([Value.t()]) :: result
  def ends_with([{:string, string}, {:string, arg}]) do
    {:ok, Value.bool(String.ends_with?(string, arg))}
  end

  def ends_with([{:bytes, bytes}, {:bytes, arg}]) do
    {:ok, Value.bool(binary_ends_with?(bytes, arg))}
  end

  def ends_with(_values), do: no_such_overload()

  @spec contains([Value.t()]) :: result
  def contains([{:string, string}, {:string, arg}]) do
    {:ok, Value.bool(String.contains?(string, arg))}
  end

  def contains([{:bytes, bytes}, {:bytes, arg}]) do
    {:ok, Value.bool(binary_contains?(bytes, arg))}
  end

  def contains(_values), do: no_such_overload()

  @spec matches([Value.t()]) :: result
  def matches([{:string, string}, {:string, pattern}]) do
    with {:ok, regex} <- Regexes.compile(pattern) do
      matches([{:string, string}, {:string, pattern}], regex)
    end
  end

  def matches(_values), do: no_such_overload()

  @spec matches([Value.t()], Regex.t()) :: result
  def matches([{:string, string}, {:string, _pattern}], %Regex{} = regex) do
    with {:ok, matched} <- Regexes.match(regex, string), do: {:ok, Value.bool(matched)}
  end

  def matches(_values, %Regex{}), do: no_such_overload()

  @spec char_at([Value.t()]) :: result
  def char_at([{:string, string}, {:int, index}]) do
    codepoints = String.codepoints(string)

    with :ok <- validate_index(index, length(codepoints)) do
      {:ok, Value.string(Enum.at(codepoints, index, ""))}
    end
  end

  def char_at(_values), do: no_such_overload()

  @spec index_of([Value.t()]) :: result
  def index_of([{:string, string}, {:string, needle}]) do
    {:ok, Value.int(index_of(string, needle, 0))}
  end

  def index_of([{:string, string}, {:string, needle}, {:int, start}]) do
    with :ok <- validate_index(start, codepoint_length(string)) do
      {:ok, Value.int(index_of(string, needle, start))}
    end
  end

  def index_of(_values), do: no_such_overload()

  @spec last_index_of([Value.t()]) :: result
  def last_index_of([{:string, string}, {:string, needle}]) do
    {:ok, Value.int(last_index_of(string, needle, codepoint_length(string)))}
  end

  def last_index_of([{:string, string}, {:string, needle}, {:int, start}]) do
    with :ok <- validate_index(start, codepoint_length(string)) do
      {:ok, Value.int(last_index_of(string, needle, start))}
    end
  end

  def last_index_of(_values), do: no_such_overload()

  @spec lower_ascii([Value.t()]) :: result
  def lower_ascii([{:string, string}]) do
    {:ok, Value.string(ascii_case(string, :lower))}
  end

  def lower_ascii(_values), do: no_such_overload()

  @spec upper_ascii([Value.t()]) :: result
  def upper_ascii([{:string, string}]) do
    {:ok, Value.string(ascii_case(string, :upper))}
  end

  def upper_ascii(_values), do: no_such_overload()

  @spec replace([Value.t()]) :: result
  def replace([{:string, string}, {:string, needle}, {:string, replacement}]) do
    {:ok, Value.string(String.replace(string, needle, replacement))}
  end

  def replace([
        {:string, string},
        {:string, needle},
        {:string, replacement},
        {:int, limit}
      ]) do
    {:ok, Value.string(replace_limited(string, needle, replacement, limit))}
  end

  def replace(_values), do: no_such_overload()

  @spec split([Value.t()]) :: result
  def split([{:string, string}, {:string, separator}]) do
    {:ok, Value.list(split_string(string, separator, :unlimited))}
  end

  def split([{:string, string}, {:string, separator}, {:int, limit}]) do
    {:ok, Value.list(split_string(string, separator, limit))}
  end

  def split(_values), do: no_such_overload()

  @spec substring([Value.t()]) :: result
  def substring([{:string, string}, {:int, start}]) do
    substring(string, start, codepoint_length(string))
  end

  def substring([{:string, string}, {:int, start}, {:int, end_index}]) do
    substring(string, start, end_index)
  end

  def substring(_values), do: no_such_overload()

  @spec trim([Value.t()]) :: result
  def trim([{:string, string}]) do
    {:ok, Value.string(trim_string(string))}
  end

  def trim(_values), do: no_such_overload()

  @spec join([Value.t()]) :: result
  def join([{:list, values}]) do
    join_strings(values, "")
  end

  def join([{:list, values}, {:string, separator}]) do
    join_strings(values, separator)
  end

  def join(_values), do: no_such_overload()

  @spec format([Value.t()]) :: result
  def format(values), do: Format.format(values)

  @spec quote([Value.t()]) :: result
  def quote([{:string, string}]) do
    {:ok, Value.string(quote_string(string))}
  end

  def quote(_values), do: no_such_overload()

  defp binary_starts_with?(bytes, prefix) when byte_size(prefix) <= byte_size(bytes) do
    prefix_size = byte_size(prefix)
    binary_part(bytes, 0, prefix_size) == prefix
  end

  defp binary_starts_with?(_bytes, _prefix), do: false

  defp binary_ends_with?(bytes, suffix) when byte_size(suffix) <= byte_size(bytes) do
    suffix_size = byte_size(suffix)
    binary_part(bytes, byte_size(bytes) - suffix_size, suffix_size) == suffix
  end

  defp binary_ends_with?(_bytes, _suffix), do: false

  defp binary_contains?(_bytes, ""), do: true

  defp binary_contains?(bytes, needle) do
    match?({_, _}, :binary.match(bytes, needle))
  end

  defp codepoint_length(string), do: string |> String.codepoints() |> length()

  defp validate_index(index, length) when index >= 0 and index <= length, do: :ok
  defp validate_index(index, _length), do: {:error, "index out of range: #{index}"}

  defp index_of(string, needle, start) do
    haystack = String.codepoints(string)
    needle = String.codepoints(needle)
    needle_length = length(needle)

    cond do
      needle_length == 0 ->
        start

      length(haystack) - needle_length < start ->
        -1

      true ->
        start..(length(haystack) - needle_length)
        |> Enum.find(-1, fn index ->
          Enum.slice(haystack, index, needle_length) == needle
        end)
    end
  end

  defp last_index_of(string, needle, start) do
    haystack = String.codepoints(string)
    needle = String.codepoints(needle)
    needle_length = length(needle)

    cond do
      needle_length == 0 ->
        start

      length(haystack) - needle_length < 0 ->
        -1

      true ->
        max_start = min(start, length(haystack) - needle_length)

        max_start..0//-1
        |> Enum.find(-1, fn index ->
          Enum.slice(haystack, index, needle_length) == needle
        end)
    end
  end

  defp ascii_case(string, direction) do
    for <<byte <- string>>, into: <<>> do
      cond do
        direction == :lower and byte in ?A..?Z -> <<byte + 32>>
        direction == :upper and byte in ?a..?z -> <<byte - 32>>
        true -> <<byte>>
      end
    end
  end

  defp replace_limited(string, needle, replacement, limit) when limit < 0 do
    String.replace(string, needle, replacement)
  end

  defp replace_limited(string, _needle, _replacement, 0), do: string

  defp replace_limited(string, "", replacement, _limit),
    do: String.replace(string, "", replacement)

  defp replace_limited(string, needle, replacement, limit) do
    case :binary.match(string, needle) do
      {index, length} ->
        prefix = binary_part(string, 0, index)
        suffix = binary_part(string, index + length, byte_size(string) - index - length)
        prefix <> replacement <> replace_limited(suffix, needle, replacement, limit - 1)

      :nomatch ->
        string
    end
  end

  defp split_string(_string, _separator, 0), do: []

  defp split_string(string, "", :unlimited) do
    Enum.map(String.codepoints(string), &Value.string/1)
  end

  defp split_string(string, "", limit) when limit < 0 do
    split_string(string, "", :unlimited)
  end

  defp split_string(string, "", limit) do
    split_codepoints(String.codepoints(string), limit)
  end

  defp split_string(string, separator, :unlimited) do
    string
    |> String.split(separator, trim: false)
    |> Enum.map(&Value.string/1)
  end

  defp split_string(string, separator, limit) when limit < 0 do
    split_string(string, separator, :unlimited)
  end

  defp split_string(string, separator, limit) do
    string
    |> String.split(separator, parts: limit, trim: false)
    |> Enum.map(&Value.string/1)
  end

  defp split_codepoints(codepoints, limit) when limit <= 1 do
    [Value.string(Enum.join(codepoints))]
  end

  defp split_codepoints([], _limit), do: []

  defp split_codepoints([head | rest], limit) do
    [Value.string(head) | split_codepoints(rest, limit - 1)]
  end

  defp substring(string, start, end_index) do
    codepoints = String.codepoints(string)
    length = length(codepoints)

    with :ok <- validate_index(start, length),
         :ok <- validate_index(end_index, length),
         :ok <- validate_substring_range(start, end_index) do
      value =
        codepoints
        |> Enum.slice(start, end_index - start)
        |> Enum.join()

      {:ok, Value.string(value)}
    end
  end

  defp validate_substring_range(start, end_index) when start <= end_index, do: :ok

  defp validate_substring_range(start, end_index),
    do: {:error, "invalid substring range. start: #{start}, end: #{end_index}"}

  defp trim_string(string) do
    string
    |> String.codepoints()
    |> Enum.drop_while(&trim_whitespace?/1)
    |> Enum.reverse()
    |> Enum.drop_while(&trim_whitespace?/1)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp trim_whitespace?(<<codepoint::utf8>>)
       when codepoint in [
              0x09,
              0x0A,
              0x0B,
              0x0C,
              0x0D,
              0x20,
              0x85,
              0xA0,
              0x1680,
              0x2028,
              0x2029,
              0x202F,
              0x205F,
              0x3000
            ] or codepoint in 0x2000..0x200A,
       do: true

  defp trim_whitespace?(_codepoint), do: false

  defp join_strings(values, separator) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      {:string, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      _value, {:ok, _acc} -> {:halt, {:error, "no such overload"}}
    end)
    |> case do
      {:ok, strings} -> {:ok, Value.string(strings |> Enum.reverse() |> Enum.join(separator))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp quote_string(string) do
    escaped =
      string
      |> String.codepoints()
      |> Enum.map_join(&quote_codepoint/1)

    "\"" <> escaped <> "\""
  end

  defp quote_codepoint("\""), do: "\\\""
  defp quote_codepoint("\\"), do: "\\\\"
  defp quote_codepoint(<<0x07>>), do: "\\a"
  defp quote_codepoint("\b"), do: "\\b"
  defp quote_codepoint("\f"), do: "\\f"
  defp quote_codepoint("\n"), do: "\\n"
  defp quote_codepoint("\r"), do: "\\r"
  defp quote_codepoint("\t"), do: "\\t"
  defp quote_codepoint(<<0x0B>>), do: "\\v"

  defp quote_codepoint(<<codepoint::utf8>>) when codepoint < 0x20 do
    "\\u" <> (codepoint |> Integer.to_string(16) |> String.pad_leading(4, "0"))
  end

  defp quote_codepoint(char), do: char

  defp no_such_overload, do: {:error, "no such overload"}
end

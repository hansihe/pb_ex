defmodule PB.TestSupport.ProtovalidateConformance.Testee do
  @moduledoc false

  alias PB.Schema.Transform
  alias PB.TestSupport.TestSchema
  alias PB.Validate.CompileError

  @request :"buf.validate.conformance.harness.TestConformanceRequest"
  @response :"buf.validate.conformance.harness.TestConformanceResponse"

  @spec main() :: no_return()
  def main do
    # The request and response are protobuf bytes, not text.
    :io.setopts(:standard_io, encoding: :latin1)

    input = IO.binread(:stdio, :eof)
    schema = TestSchema.schema()

    response =
      case PB.decode(input, schema, @request) do
        {:ok, request} ->
          safe_response(fn -> run_request(request) end)

        {:error, error} ->
          fatal("failed to decode TestConformanceRequest: #{Exception.message(error)}")
      end

    case PB.encode(response, schema, @response) do
      {:ok, encoded} ->
        IO.binwrite(:stdio, IO.iodata_to_binary(encoded))
        System.halt(0)

      {:error, error} ->
        fatal("failed to encode TestConformanceResponse: #{Exception.message(error)}")
    end
  end

  defp safe_response(fun) do
    fun.()
  rescue
    exception ->
      all_cases_result(%{}, unexpected_error(Exception.format(:error, exception, __STACKTRACE__)))
  catch
    kind, reason ->
      all_cases_result(%{}, unexpected_error("caught #{inspect(kind)}: #{inspect(reason)}"))
  end

  defp run_request(%{fdset: descriptor_set} = request) do
    cases = Map.get(request, :cases, %{})

    case compile_base_schema(descriptor_set) do
      {:ok, schema} ->
        message_types = Map.new(Map.keys(schema.messages), &{Atom.to_string(&1), &1})

        {results, _schema_cache} =
          Enum.reduce(cases, {%{}, %{}}, fn {case_name, test_case}, {results, schema_cache} ->
            {result, schema_cache} = run_case(schema, message_types, schema_cache, test_case)
            {Map.put(results, case_name, result), schema_cache}
          end)

        %{results: results}

      {:error, reason} ->
        all_cases_result(cases, compilation_error(reason))
    end
  end

  # The base schema is compiled without validation, so a case whose rules don't
  # compile fails on its own; each case compiles the rules of its message's
  # slice.
  defp compile_base_schema(descriptor_set) do
    {:ok, PB.compile(descriptor_set)}
  rescue
    exception -> {:error, Exception.format(:error, exception, __STACKTRACE__)}
  catch
    kind, reason -> {:error, "caught #{inspect(kind)}: #{inspect(reason)}"}
  end

  defp run_case(base_schema, message_types, schema_cache, %{type_url: type_url} = test_case)
       when is_binary(type_url) do
    payload = Map.get(test_case, :value, <<>>)

    with {:ok, message_name} <- fetch_message_type(message_types, type_url),
         {:ok, decoded} <- decode_payload(base_schema, message_name, payload) do
      case fetch_case_schema(base_schema, message_name, schema_cache) do
        {:ok, schema, schema_cache} ->
          {validate_case(schema, message_name, decoded), schema_cache}

        {:error, reason, schema_cache} ->
          {compilation_error(reason), schema_cache}
      end
    else
      {:error, reason} -> {unexpected_error(reason), schema_cache}
    end
  end

  defp run_case(_base_schema, _message_types, schema_cache, other) do
    {unexpected_error("invalid Any test case #{inspect(other)}"), schema_cache}
  end

  defp fetch_case_schema(base_schema, message_name, schema_cache) do
    case Map.fetch(schema_cache, message_name) do
      {:ok, {:ok, schema}} ->
        {:ok, schema, schema_cache}

      {:ok, {:error, reason}} ->
        {:error, reason, schema_cache}

      :error ->
        case compile_case_schema(base_schema, message_name) do
          {:ok, schema} ->
            {:ok, schema, Map.put(schema_cache, message_name, {:ok, schema})}

          {:error, reason} ->
            {:error, reason, Map.put(schema_cache, message_name, {:error, reason})}
        end
    end
  end

  @doc false
  # Public for the unit test that covers this schema-building path, since the
  # conformance runner needs Go.
  def compile_case_schema(base_schema, message_name) do
    schema =
      base_schema
      |> Transform.slice(roots: [message_name])
      |> PB.Validate.compile([])

    {:ok, schema}
  rescue
    exception in [CompileError] ->
      {:error, Exception.message(exception)}

    exception ->
      {:error, Exception.format(:error, exception, __STACKTRACE__)}
  catch
    kind, reason ->
      {:error, "caught #{inspect(kind)}: #{inspect(reason)}"}
  end

  defp validate_case(schema, message_name, decoded) do
    decoded
    |> PB.Validate.validate(schema, message_name)
    |> validation_result()
  rescue
    exception in [RuntimeError] ->
      runtime_error(Exception.message(exception))

    exception ->
      unexpected_error(Exception.format(:error, exception, __STACKTRACE__))
  catch
    kind, reason ->
      unexpected_error("caught #{inspect(kind)}: #{inspect(reason)}")
  end

  defp fetch_message_type(message_types, type_url) do
    message_type =
      type_url
      |> String.split("/")
      |> List.last()

    case Map.fetch(message_types, message_type) do
      {:ok, message_name} -> {:ok, message_name}
      :error -> {:error, "unknown conformance message type #{inspect(message_type)}"}
    end
  end

  defp decode_payload(schema, message_name, payload) do
    case PB.decode(payload, schema, message_name) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, "failed to decode #{message_name}: #{Exception.message(error)}"}
    end
  end

  defp all_cases_result(cases, result) do
    %{results: Map.new(cases, fn {case_name, _test_case} -> {case_name, result} end)}
  end

  defp validation_result(:ok), do: success()

  defp validation_result({:error, %PB.Validate.Error{} = error}),
    do: %{result: {:validation_error, PB.Validate.to_proto_violations(error)}}

  defp validation_result({:error, %CEL.Error{} = error}),
    do: runtime_error(Exception.message(error))

  defp validation_result({:error, error}), do: unexpected_error(Exception.message(error))

  defp success, do: %{result: {:success, true}}
  defp compilation_error(message), do: %{result: {:compilation_error, message}}
  defp runtime_error(message), do: %{result: {:runtime_error, message}}
  defp unexpected_error(message), do: %{result: {:unexpected_error, message}}

  defp fatal(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end

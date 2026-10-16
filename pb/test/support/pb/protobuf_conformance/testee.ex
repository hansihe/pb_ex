defmodule PB.TestSupport.ProtobufConformance.Testee do
  @moduledoc false

  alias PB.TestSupport.Conformance.Stdio
  alias PB.TestSupport.TestSchema

  @request :"conformance.ConformanceRequest"
  @response :"conformance.ConformanceResponse"
  @failure_set :"conformance.FailureSet"

  @spec main() :: no_return()
  def main do
    Stdio.configure!()

    schema = TestSchema.schema()
    message_types = Map.new(Map.keys(schema.messages), &{Atom.to_string(&1), &1})

    loop(schema, message_types)
  end

  defp loop(schema, message_types) do
    case Stdio.read_frame() do
      {:ok, frame} ->
        response = handle_frame(schema, message_types, frame)

        case PB.encode(response, schema, @response) do
          {:ok, encoded} ->
            :ok = Stdio.write_frame(IO.iodata_to_binary(encoded))
            loop(schema, message_types)

          {:error, error} ->
            fatal("failed to encode ConformanceResponse: #{Exception.message(error)}")
        end

      :eof ->
        System.halt(0)

      {:error, reason} ->
        fatal("failed to read conformance frame: #{inspect(reason)}")
    end
  end

  defp handle_frame(schema, message_types, frame) do
    case PB.decode(frame, schema, @request) do
      {:ok, request} ->
        safe_response(fn -> run_request(schema, message_types, request) end)

      {:error, error} ->
        runtime_error("failed to decode ConformanceRequest: #{Exception.message(error)}")
    end
  end

  defp safe_response(fun) do
    fun.()
  rescue
    exception ->
      runtime_error(Exception.format(:error, exception, __STACKTRACE__))
  catch
    kind, reason ->
      runtime_error("caught #{inspect(kind)}: #{inspect(reason)}")
  end

  defp run_request(schema, _message_types, %{message_type: "conformance.FailureSet"}) do
    with {:ok, encoded} <- PB.encode(%{}, schema, @failure_set) do
      protobuf_payload(IO.iodata_to_binary(encoded))
    else
      {:error, error} -> runtime_error("failed to encode FailureSet: #{Exception.message(error)}")
    end
  end

  defp run_request(schema, message_types, request) do
    message_type = Map.get(request, :message_type, "")

    with {:ok, message_name} <- fetch_message_type(message_types, message_type),
         {:ok, decoded} <- decode_input(schema, message_name, request) do
      encode_output(schema, message_name, decoded, request)
    else
      {:skip, reason} -> skipped(reason)
      {:parse_error, reason} -> parse_error(reason)
      {:runtime_error, reason} -> runtime_error(reason)
    end
  end

  defp fetch_message_type(message_types, message_type) do
    case Map.fetch(message_types, message_type) do
      {:ok, message_name} -> {:ok, message_name}
      :error -> {:runtime_error, "unknown conformance message type #{inspect(message_type)}"}
    end
  end

  defp decode_input(schema, message_name, %{payload: {:protobuf_payload, payload}})
       when is_binary(payload) do
    case PB.decode(payload, schema, message_name) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:parse_error, Exception.message(error)}
    end
  end

  defp decode_input(schema, message_name, %{payload: {:json_payload, payload}} = request)
       when is_binary(payload) do
    opts = json_decode_opts(request)

    case PB.JSON.decode(payload, schema, message_name, opts) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:parse_error, Exception.message(error)}
    end
  end

  defp decode_input(_schema, _message_name, %{payload: {:jspb_payload, _payload}}),
    do: {:skip, "JSPB conformance is not supported by PB"}

  defp decode_input(schema, message_name, %{payload: {:text_payload, payload}})
       when is_binary(payload) do
    case PB.TextFormat.decode(payload, schema, message_name) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:parse_error, Exception.message(error)}
    end
  end

  defp decode_input(_schema, _message_name, _request),
    do: {:runtime_error, "request did not include a payload"}

  defp json_decode_opts(request) do
    case Map.get(request, :test_category) do
      :JSON_IGNORE_UNKNOWN_PARSING_TEST -> [unknown_fields: :ignore]
      _ -> []
    end
  end

  defp encode_output(schema, message_name, decoded, request) do
    encode_output(
      schema,
      message_name,
      decoded,
      Map.get(request, :requested_output_format),
      request
    )
  end

  defp encode_output(schema, message_name, decoded, :PROTOBUF, _request) do
    case PB.encode(decoded, schema, message_name) do
      {:ok, encoded} -> protobuf_payload(IO.iodata_to_binary(encoded))
      {:error, error} -> serialize_error(Exception.message(error))
    end
  end

  defp encode_output(schema, message_name, decoded, :JSON, _request) do
    case PB.JSON.encode(decoded, schema, message_name) do
      {:ok, payload} -> json_payload(payload)
      {:error, error} -> serialize_error(Exception.message(error))
    end
  end

  defp encode_output(_schema, _message_name, _decoded, :JSPB, _request),
    do: skipped("JSPB conformance is not supported by PB")

  defp encode_output(schema, message_name, decoded, :TEXT_FORMAT, request) do
    opts = [print_unknown_fields: Map.get(request, :print_unknown_fields, false)]

    case PB.TextFormat.encode(decoded, schema, message_name, opts) do
      {:ok, payload} -> text_payload(payload)
      {:error, error} -> serialize_error(Exception.message(error))
    end
  end

  defp encode_output(_schema, _message_name, _decoded, format, _request),
    do: runtime_error("unsupported requested output format #{inspect(format)}")

  defp parse_error(message), do: %{result: {:parse_error, message}}
  defp protobuf_payload(payload), do: %{result: {:protobuf_payload, payload}}
  defp json_payload(payload), do: %{result: {:json_payload, payload}}
  defp text_payload(payload), do: %{result: {:text_payload, payload}}
  defp runtime_error(message), do: %{result: {:runtime_error, message}}
  defp serialize_error(message), do: %{result: {:serialize_error, message}}
  defp skipped(message), do: %{result: {:skipped, message}}

  defp fatal(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end

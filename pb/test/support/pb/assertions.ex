defmodule PB.TestSupport.Assertions do
  @moduledoc false

  import ExUnit.Assertions

  def assert_error(result, attrs) do
    assert {:error, %{__exception__: true} = error} = result

    Enum.each(attrs, fn {key, expected} ->
      assert Map.fetch!(error, key) == expected
    end)

    error
  end
end

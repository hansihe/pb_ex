defmodule PBValidate.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/hansihe/pb_ex"

  def project do
    [
      app: :pb_validate,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "PB.Validate",
      description: description(),
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # PB.Validate uses internals of pb (the prepared schema and its runtime
      # modules) and of cel_ex, so pb_validate will pin both to an exact version
      # (`== x.y.z`) when published.
      {:pb, path: "../pb"},
      {:cel_ex, path: "../cel_ex"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      files: ["lib", "mix.exs", "README*"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp description do
    """
    protovalidate validation for PB.
    """
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      # The project lives in the pb_validate/ subdirectory of the repository.
      source_url_pattern: "#{@source_url}/blob/v#{@version}/pb_validate/%{path}#L%{line}",
      extras: extras(),
      groups_for_extras: [Guides: ~r"guides/.*"],
      groups_for_modules: groups_for_modules(),
      nest_modules_by_prefix: [
        PB.Validate
      ]
    ]
  end

  defp extras do
    [
      "README.md",
      "guides/validation.md",
      "guides/conformance.md"
    ]
  end

  defp groups_for_modules do
    [
      Validation: [
        PB.Validate,
        PB.Validate.Error,
        PB.Validate.Violation
      ],
      Errors: [
        PB.Validate.CompileError
      ]
    ]
  end
end

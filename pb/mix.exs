defmodule PB.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/hansihe/pb_ex"

  def project do
    [
      app: :pb,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "PB",
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
      # PB's CEL binding and protovalidate use CEL internals, so pb will pin
      # cel_ex to an exact version (`== x.y.z`) when published.
      {:cel_ex, path: "../cel_ex"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:tzdata, "~> 1.1", only: :test}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      files: ["lib", "priv", "proto", "mix.exs", "README*"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp description do
    """
    Data-driven protobuf toolkit for Elixir.
    """
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      # The project lives in the pb/ subdirectory of the repository.
      source_url_pattern: "#{@source_url}/blob/v#{@version}/pb/%{path}#L%{line}",
      extras: extras(),
      groups_for_extras: groups_for_extras(),
      groups_for_modules: groups_for_modules(),
      nest_modules_by_prefix: [
        PB.Schema,
        PB.WellKnownTypes,
        PB.Validate
      ]
    ]
  end

  # Documentation pages, organised along the Diátaxis framework:
  # tutorials (learning), how-to guides (tasks), reference (information),
  # and explanation (understanding). See guides/ for the source files.
  defp extras do
    [
      "README.md",
      # Tutorial
      "guides/tutorials/getting-started.md",
      # How-to guides
      "guides/how-to/descriptor-sets.md",
      "guides/how-to/schema-modules.md",
      "guides/how-to/structs-and-representation.md",
      "guides/how-to/adapters-and-well-known-types.md",
      "guides/how-to/json.md",
      "guides/how-to/validation.md",
      "guides/how-to/cel.md",
      "guides/how-to/extensions-and-unknown-fields.md",
      "guides/how-to/introspection.md",
      # Reference
      "guides/reference/data-representation.md",
      "guides/reference/options.md",
      "guides/reference/conformance.md",
      "guides/reference/benchmarks.md",
      # Explanation
      "guides/explanation/why-data-driven.md",
      "guides/explanation/encoding-semantics.md",
      "guides/explanation/representation-vs-adapters.md"
    ]
  end

  defp groups_for_extras do
    [
      Tutorials: ~r"guides/tutorials/.*",
      "How-to guides": ~r"guides/how-to/.*",
      Reference: ~r"guides/reference/.*",
      Explanation: ~r"guides/explanation/.*"
    ]
  end

  defp groups_for_modules do
    [
      Core: [
        PB,
        PB.JSON,
        PB.TextFormat,
        PB.UnknownField
      ],
      "Schema & introspection": [
        PB.Schema,
        PB.Schema.Info,
        PB.Schema.Projection
      ],
      "Representation & adapters": [
        PB.Adapter,
        PB.WellKnownTypes
      ],
      CEL: [
        PB.CEL
      ],
      Validation: [
        PB.Validate,
        PB.Validate.Error,
        PB.Validate.Violation
      ],
      Errors: [
        PB.Error,
        PB.SchemaError,
        PB.ValueError,
        PB.DecodeError,
        PB.OptionError,
        PB.AdapterError,
        PB.Validate.CompileError
      ]
    ]
  end
end

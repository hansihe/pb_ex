defmodule PBCEL.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/hansihe/pb_ex"

  def project do
    [
      app: :pb_cel,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "PB.CEL",
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
      # PB.CEL implements cel_ex's type provider over pb's prepared schema and
      # runtime modules, internals of both, so pb_cel will pin pb and cel_ex to
      # an exact version (`== x.y.z`) when published.
      {:pb, path: "../pb"},
      {:cel_ex, path: "../cel_ex"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      # CEL conformance uses named time zones.
      {:tzdata, "~> 1.1", only: :test}
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
    CEL over protobuf messages: a CEL type provider for PB.
    """
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      # The project lives in the pb_cel/ subdirectory of the repository.
      source_url_pattern: "#{@source_url}/blob/v#{@version}/pb_cel/%{path}#L%{line}",
      extras: extras(),
      groups_for_extras: [Guides: ~r"guides/.*"],
      groups_for_modules: groups_for_modules()
    ]
  end

  defp extras do
    [
      "README.md",
      "guides/cel-over-protobuf.md",
      "guides/conformance.md"
    ]
  end

  defp groups_for_modules do
    [
      CEL: [
        PB.CEL
      ]
    ]
  end
end

defmodule PBCEL.MixProject do
  use Mix.Project

  @version "0.2.0"
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
      # runtime modules, internals of both, so it pins them to its own version.
      sibling(:pb),
      sibling(:cel_ex),
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      # CEL conformance uses named time zones.
      {:tzdata, "~> 1.1", only: :test}
    ]
  end

  # The libraries in this repository are released together at one version.
  # Consumers evaluate this file too, so the Hex requirement is the default;
  # inside the repository, mise.toml sets PB_EX_LOCAL=1 to use the sibling
  # checkouts instead.
  defp sibling(app) do
    if System.get_env("PB_EX_LOCAL") == "1" do
      {app, path: "../#{app}"}
    else
      {app, "== #{@version}"}
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      files: ["lib", "priv", "mix.exs", "README*", "LICENSE", "CHANGELOG.md"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://hexdocs.pm/pb_cel/changelog.html"
      }
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
      "CHANGELOG.md",
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

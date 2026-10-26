defmodule PBValidate.MixProject do
  use Mix.Project

  @version "0.2.0"
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
      # modules), pb_cel (its CEL message runtime) and cel_ex (the evaluator),
      # so it pins all three to its own version.
      sibling(:pb),
      sibling(:pb_cel),
      sibling(:cel_ex),
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
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
        "Changelog" => "https://hexdocs.pm/pb_validate/changelog.html"
      }
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
      "CHANGELOG.md",
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

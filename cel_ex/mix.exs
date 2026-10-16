defmodule CELEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/hansihe/pb_ex"

  def project do
    [
      app: :cel_ex,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "CEL",
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
    Common Expression Language (CEL) for Elixir.
    """
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      # The project lives in the cel_ex/ subdirectory of the repository.
      source_url_pattern: "#{@source_url}/blob/v#{@version}/cel_ex/%{path}#L%{line}",
      extras: extras(),
      groups_for_modules: groups_for_modules(),
      nest_modules_by_prefix: [
        CEL
      ]
    ]
  end

  defp extras do
    [
      "README.md"
    ]
  end

  defp groups_for_modules do
    [
      CEL: [
        CEL,
        CEL.Env,
        CEL.Program,
        CEL.Checked,
        CEL.Expr,
        CEL.Function,
        CEL.Function.Overload,
        CEL.Type,
        CEL.TypeProvider,
        CEL.Field,
        CEL.Value,
        CEL.Unknown
      ],
      "CEL expression view": [
        CEL.Expr.Const,
        CEL.Expr.Ident,
        CEL.Expr.Select,
        CEL.Expr.Call,
        CEL.Expr.MacroCall,
        CEL.Expr.ListLiteral,
        CEL.Expr.MapLiteral,
        CEL.Expr.MessageLiteral,
        CEL.Expr.Comprehension
      ],
      Errors: [
        CEL.Error,
        CEL.OptionError
      ]
    ]
  end
end

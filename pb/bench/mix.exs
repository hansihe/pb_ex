defmodule PBBench.MixProject do
  use Mix.Project

  # Self-contained benchmark project. It carries the benchmark-only deps
  # (`benchee`, the Elixir `protobuf` library) so the main `pb` project stays
  # dependency-free. `pb` itself is pulled in as a path dependency.
  #
  # Benchmarks (run from this directory):
  #
  #     cd bench && mix run pb_vs_protobuf.exs    # PB vs the `protobuf` library
  #     cd bench && mix run codegen_vs_runtime.exs # PB runtime vs codegen path
  #
  # Or regenerate proto artifacts, rerun the PB-vs-protobuf suite, and refresh
  # the docs results block:
  #
  #     bench/run.sh
  def project do
    [
      app: :pb_bench,
      version: "0.0.0",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:pb, path: ".."},
      {:benchee, "~> 1.3"},
      {:protobuf, "~> 0.13"}
    ]
  end
end

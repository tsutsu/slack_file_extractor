defmodule SlackFileExtractor.MixProject do
  use Mix.Project

  def project do
    [
      app: :slack_file_extractor,
      version: "0.1.0",
      elixir: "~> 1.6",
      elixirc_paths: elixirc_paths(Mix.env),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [
    mod: {SlackFileExtractor.Application, []},
    extra_applications: [:logger]
  ]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_),     do: ["lib"]

  defp deps, do: [
    {:jason, "~> 1.1"},
    {:httpoison, "~> 1.2"},
    {:durable_workflow, "~> 0.1.1"},
    {:pretty_console, "~> 0.2.1"},
    {:etfs, "~> 0.1.2"},
    {:temp, "~> 0.4.5"},
    {:timex, "~> 3.3"},
    {:progress_bar, "~> 1.6"}
  ]
end

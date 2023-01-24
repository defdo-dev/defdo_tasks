defmodule Defdo.Tasks.MixProject do
  use Mix.Project

  @organization "defdo"

  def project do
    [
      app: :defdo_tasks,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A set of mix tasks to work with defdo_apps.",
      package: package(),
      # exdocs
      name: "Defdo.Tasks",
      source_url: "https://github.com/defdo-dev/defdo_tasks",
      homepage_url: "https://foss.defdo.ninja",
      docs: [
        # The main page in the docs
        # main: "Defdo.Tasks.Application",
        # logo: "logo.png",
        extras: ["README.md"]
      ]
    ]
  end

  defp package do
    [
      organization: @organization,
      licenses: ["Apache-2.0"],
      links: %{}
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Defdo.Tasks.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.22", only: :dev, runtime: false},
    ]
  end
end

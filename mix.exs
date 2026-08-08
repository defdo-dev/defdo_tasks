defmodule Defdo.Tasks.MixProject do
  use Mix.Project

  @organization "defdo"
  @version "0.2.0"
  @source_url "https://github.com/defdo-dev/defdo_tasks"

  def project do
    [
      app: :defdo_tasks,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: "Mix tasks that scaffold and audit defdo SaaS apps.",
      package: package(),
      # exdocs
      name: "Defdo.Tasks",
      source_url: @source_url,
      homepage_url: "https://foss.defdo.ninja",
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      organization: @organization,
      licenses: ["Apache-2.0"],
      files: ~w(lib CHANGELOG.md LICENSE.md mix.exs README.md .formatter.exs),
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        "SaaS stack": [
          Defdo.Tasks.Saas.MigratorChain,
          Defdo.Tasks.Saas.OAuthClient,
          Defdo.Tasks.Saas.Stack
        ]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    # No `mod:` on purpose. This package is mix tasks and pure helper modules;
    # consumers depend on it with `runtime: false`, so starting a supervisor
    # that owns nothing only makes the dependency look heavier than it is.
    [extra_applications: [:logger]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Optional so the package still compiles and its plain Mix tasks still run
      # in a project that has not adopted Igniter. The generator tasks are
      # compiled only when Igniter is present -- the same guard defdo_tenant
      # uses for `mix defdo_tenant.install`.
      {:igniter, "~> 0.6 or ~> 0.7 or ~> 0.8", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end

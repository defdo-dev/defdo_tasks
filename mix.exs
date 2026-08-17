defmodule Defdo.Tasks.MixProject do
  use Mix.Project

  @organization "defdo"
  @version "0.4.1"
  @source_url "https://github.com/defdo-dev/defdo_tasks"

  def project do
    [
      app: :defdo_tasks,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      description: "Mix tasks that scaffold and audit defdo SaaS apps.",
      package: package(),
      # exdocs
      name: "Defdo.Tasks",
      source_url: @source_url,
      homepage_url: "https://foss.defdo.ninja",
      docs: docs()
    ]
  end

  # `precommit` ends in `mix test`, which refuses to run outside the test env.
  def cli do
    [preferred_envs: [precommit: :test]]
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
      source_ref: @version,
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
      # Required, not transitive: the MCP tools/call payloads are encoded here
      # directly (`lib/defdo/tasks/mcp`), so a consuming app without Igniter
      # (which is the only other path jason previously arrived by) must still
      # get it.
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # No `precommit` alias existed on this branch (verified: `mix help precommit`
  # raised "The task \"precommit\" could not be found"), even though issue #4's
  # gate calls it "a real gate in this repo".
  #
  # Every step here must *check* rather than *fix*, or the gate passes by
  # repairing what it was meant to catch. The shape most of the estate carries
  # — `deps.unlock --unused` and a bare `format` — does exactly that: the first
  # rewrites mix.lock, the second rewrites the source, and then `test` runs
  # against the repaired tree and reports green. Their checking forms are
  # `--check-unused` and `--check-formatted`. Same defect was just removed from
  # defdo_order_visor; do not copy the majority shape back in.
  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "test"
      ]
    ]
  end
end

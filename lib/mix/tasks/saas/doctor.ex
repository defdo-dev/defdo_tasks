defmodule Mix.Tasks.Defdo.Saas.Doctor do
  @shortdoc "Audits a defdo SaaS app against the stack"

  @moduledoc """
  Audits the current app against the defdo SaaS stack and reports what is wrong.

      mix defdo.saas.doctor
      mix defdo.saas.doctor --strict
      mix defdo.saas.doctor --oauth-grants client_credentials,introspect --oauth-confidential

  This is the check `mix defdo.saas.install` builds into a new app for free, run
  against an app that already exists. It needs no Igniter and does not modify
  anything.

  ## What it checks

    * **The tenant migrator chain.** Whether this app carries a wrapper for the
      current `Defdo.Tenant.Migrator` version, and whether that wrapper pins a
      version at all. An app that stops at v3 fails at runtime with
      `column t0.deleted_at does not exist` the moment it resolves
      defdo_tenant 0.11+.

    * **Stack dependencies.** Whether the core packages are declared, and
      whether any requirement is pinned so tightly it cannot admit the version
      the stack targets. This comparison needs the current release from the
      private `defdo` Hex organization; when it cannot be resolved (expired
      Hex session, offline, no organization key) the check reports a WARNING
      saying it did not run, because an un-run check is unknown rather than
      ok. Export `HEX_API_KEY="$HEX_ORG_TOKEN"` -- it is forwarded to
      `mix hex.info` -- for a run that actually performs the comparison.

    * **`defdo_compiled_config.exs` drift.** Whether the repo flavour still
      returns `[type: :binary_id]` for migration keys.

    * **The OAuth service client shape**, when one is supplied on the command
      line.

  ## Options

    * `--strict` — exit 1 on warnings as well as errors
    * `--migrations-path` — defaults to `priv/repo/migrations`
    * `--config-path` — defaults to `config`
    * `--oauth-grants` — comma-separated grant list to validate
    * `--oauth-confidential` / `--no-oauth-confidential`
    * `--oauth-auth-methods` — comma-separated token endpoint auth methods
    * `--oauth-role` — `instance_service` (default) or `platform_introspection`

  ## Exit status

  Exits 1 when any error is found, so it can gate a pipeline. `--strict` also
  fails on warnings -- which includes a check that could not run at all, so a
  `--strict` gate is never satisfied by silence.
  """

  use Mix.Task

  alias Defdo.Tasks.Saas.Audit
  alias Defdo.Tasks.Saas.HexBaseline
  alias Defdo.Tasks.Saas.Stack

  @switches [
    strict: :boolean,
    migrations_path: :string,
    config_path: :string,
    oauth_grants: :string,
    oauth_confidential: :boolean,
    oauth_auth_methods: :string,
    oauth_role: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    findings =
      Audit.run(".",
        migrations_path: opts[:migrations_path] || Path.join(["priv", "repo", "migrations"]),
        config_path: opts[:config_path] || "config",
        deps: project_deps(),
        hex_baseline: hex_baseline(),
        oauth: oauth_client(opts),
        oauth_role: oauth_role(opts)
      )

    report(findings)

    case Audit.exit_status(findings, strict: opts[:strict] || false) do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end

  defp project_deps do
    case Mix.Project.get() do
      nil -> []
      _module -> Mix.Project.config()[:deps] || []
    end
  end

  # Resolves the live "what does Hex currently publish" baseline once per
  # run, for every stack package `check_deps/2` might have an opinion about.
  # A failure here (offline, expired auth, no `defdo` organization key) never
  # raises -- `HexBaseline.resolve/2` always returns `{:error, reason}`, and
  # `Audit.check_deps/2` renders that as a WARNING (the check did not run;
  # that is unknown, not ok) rather than falling back to any hardcoded number.
  # `HexBaseline` forwards `HEX_API_KEY`/`HEX_ORG_TOKEN` from the ambient
  # environment to `mix hex.info`, so a caller whose `mix deps.get` works can
  # normally resolve the baseline too.
  defp hex_baseline do
    Stack.select() |> Enum.map(& &1.name) |> HexBaseline.resolve_all()
  end

  defp oauth_client(opts) do
    case opts[:oauth_grants] do
      nil ->
        nil

      grants ->
        %{
          supported_grant_types: split(grants),
          confidential: Keyword.get(opts, :oauth_confidential, nil),
          token_endpoint_auth_methods: split(opts[:oauth_auth_methods])
        }
    end
  end

  defp oauth_role(opts) do
    case opts[:oauth_role] do
      nil ->
        :instance_service

      "platform_introspection" ->
        :platform_introspection

      "instance_service" ->
        :instance_service

      other ->
        Mix.raise(
          "unknown --oauth-role #{inspect(other)}, expected instance_service or platform_introspection"
        )
    end
  end

  defp split(nil), do: []
  defp split(value), do: String.split(value, ",", trim: true) |> Enum.map(&String.trim/1)

  defp report([]) do
    Mix.shell().info("defdo.saas.doctor: nothing to report.")
  end

  defp report(findings) do
    counts = Enum.frequencies_by(findings, & &1.severity)

    Mix.shell().info("")

    for finding <- Enum.sort_by(findings, &severity_rank(&1.severity)) do
      Mix.shell().info("#{label(finding.severity)} [#{finding.check}] #{finding.message}")

      if finding.remedy do
        Mix.shell().info("        fix: #{indent_continuation(finding.remedy)}")
      end

      Mix.shell().info("")
    end

    Mix.shell().info(
      "#{Map.get(counts, :error, 0)} error(s), " <>
        "#{Map.get(counts, :warning, 0)} warning(s), " <>
        "#{Map.get(counts, :info, 0)} note(s)."
    )
  end

  # A remedy may be a multi-line command. Line up its continuations under the
  # first line rather than letting them fall back to column zero, where they
  # read as separate findings.
  defp indent_continuation(remedy) do
    remedy
    |> String.split("\n")
    |> Enum.join("\n             ")
  end

  defp severity_rank(:error), do: 0
  defp severity_rank(:warning), do: 1
  defp severity_rank(:info), do: 2

  defp label(:error), do: "ERROR  "
  defp label(:warning), do: "WARNING"
  defp label(:info), do: "ok     "
end

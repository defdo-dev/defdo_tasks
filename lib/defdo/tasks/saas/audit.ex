defmodule Defdo.Tasks.Saas.Audit do
  @moduledoc """
  Checks a defdo SaaS app against the stack, as pure functions.

  `mix defdo.saas.doctor` is a thin renderer over this module. The checks live
  here so they can be tested against fixture directories without a Mix project,
  and so an app can call them from its own CI without shelling out.

  Every check returns a list of `t:finding/0`. A finding is deliberately not a
  string: `:check` lets a caller filter, and `:remedy` carries the command that
  fixes it, because a report that names a problem without naming its fix just
  moves the work.
  """

  alias Defdo.Tasks.Saas.MigratorChain
  alias Defdo.Tasks.Saas.OAuthClient
  alias Defdo.Tasks.Saas.Stack

  @typedoc "One audit finding."
  @type finding :: %{
          check: atom(),
          severity: :error | :warning | :info,
          message: String.t(),
          remedy: String.t() | nil
        }

  @doc """
  Runs every check that can be run from the given project root.

  Options:

    * `:migrations_path` — defaults to `priv/repo/migrations` under `root`
    * `:deps` — the project's dep list, as `Mix.Project.config()[:deps]` returns it
    * `:config_path` — defaults to `config` under `root`
    * `:oauth` — a client attrs map to validate, plus `:oauth_role`
  """
  @spec run(String.t(), keyword()) :: [finding()]
  def run(root \\ ".", opts \\ []) do
    migrations_path =
      Keyword.get(opts, :migrations_path, Path.join([root, "priv", "repo", "migrations"]))

    config_path = Keyword.get(opts, :config_path, Path.join(root, "config"))

    check_migrator_chain(migrations_path) ++
      check_deps(Keyword.get(opts, :deps, [])) ++
      check_compiled_config(config_path) ++
      check_oauth(Keyword.get(opts, :oauth), Keyword.get(opts, :oauth_role, :instance_service))
  end

  @doc """
  The trap: does this app carry the current tenant migrator version?

  Reports a missing wrapper, a wrapper that stops short of the current version,
  a wrapper with no `version:` at all, and a wrapper whose `down` reverts more
  than its `up` applied.
  """
  @spec check_migrator_chain(String.t()) :: [finding()]
  def check_migrator_chain(migrations_path) do
    wrappers = MigratorChain.scan_path(migrations_path)

    {target, confidence} =
      case MigratorChain.target_version() do
        {:ok, version} -> {version, :verified}
        {:assumed, version} -> {version, :assumed}
      end

    status_findings =
      wrappers
      |> MigratorChain.status(target)
      |> status_finding(target, migrations_path)

    asymmetry_findings =
      for w <- MigratorChain.asymmetric(wrappers) do
        warning(
          :migrator_rollback,
          "#{w.file} runs `up(version: #{w.up})` but `down(version: #{w.down})`. " <>
            "`down/1` rolls back down to *and including* the version given, so this " <>
            "reverts #{w.up - w.down} step(s) it never applied.",
          "change `down` to version: #{w.up}"
        )
      end

    confidence_findings =
      if confidence == :assumed do
        [
          warning(
            :migrator_chain,
            "`Defdo.Tenant.Migrator` is not loadable here, so v#{target} is the last version " <>
              "this package knows about rather than a reading of what you have installed. " <>
              "Run this from a project with defdo_tenant compiled for a verified answer."
          )
        ]
      else
        []
      end

    confidence_findings ++ status_findings ++ asymmetry_findings ++ prefix_findings(wrappers)
  end

  defp status_finding(:current, target, _migrations_path) do
    [info(:migrator_chain, "tenant migrator wrapper is at v#{target}, the current version")]
  end

  defp status_finding({:missing, version}, _target, migrations_path) do
    [
      error(
        :migrator_chain,
        "no `Defdo.Tenant.Migrator` wrapper migration in #{migrations_path}. " <>
          "Versions 1..3 may still arrive through defdo_vault's chain, but nothing " <>
          "carries v#{version} -- `tenant_profiles` will lack `deleted_at` and every " <>
          "profile read will fail with `column t0.deleted_at does not exist`.",
        "mix defdo.saas.migrations"
      )
    ]
  end

  defp status_finding({:behind, applied, version}, _target, _migrations_path) do
    [
      error(
        :migrator_chain,
        "tenant migrator wrapper stops at v#{applied}, but v#{version} is available. " <>
          "v4 adds `tenant_profiles.deleted_at`, which defdo_tenant 0.11+ selects on " <>
          "every profile read.",
        "mix defdo.saas.migrations"
      )
    ]
  end

  defp status_finding({:floating, files}, _target, _migrations_path) do
    [
      error(
        :migrator_chain,
        "wrapper migration#{if length(files) > 1, do: "s", else: ""} " <>
          "#{Enum.join(files, ", ")} call `Defdo.Tenant.Migrator.up/1` with no " <>
          "`version:`. The schema they produce is whatever version of defdo_tenant " <>
          "happened to be installed the first time they ran, so environments diverge " <>
          "silently.",
        "pin the version explicitly, then `mix defdo.saas.migrations` for anything newer"
      )
    ]
  end

  # Wrappers that disagree with each other about which Postgres schema the
  # tenant tables live in. This does not fail the migration run -- it builds two
  # independent copies of `tenant_profiles` and lets `search_path` decide which
  # one the app reads.
  defp prefix_findings(wrappers) do
    case wrappers
         |> Enum.map(&Map.get(&1, :prefix))
         |> Enum.filter(&is_binary/1)
         |> Enum.uniq() do
      prefixes when length(prefixes) > 1 ->
        [
          error(
            :migrator_prefix,
            "tenant migrator wrappers disagree about the schema prefix: " <>
              "#{Enum.map_join(prefixes, ", ", &inspect/1)}. Each prefix gets its own " <>
              "`tenant_profiles`, and the repo's `search_path` decides which one is read.",
            "pick one prefix and reconcile the wrappers before the next `mix ecto.migrate`"
          )
        ]

      _one_or_none ->
        []
    end
  end

  @doc """
  Are the stack dependencies present, and can their requirements still admit the
  version the stack targets?
  """
  @spec check_deps(list()) :: [finding()]
  def check_deps(deps) when is_list(deps) do
    declared = Map.new(deps, &normalize_dep/1)

    Enum.flat_map(Stack.select(), fn dep ->
      case Map.fetch(declared, dep.name) do
        :error when dep.tier == :core ->
          [
            error(
              :stack_deps,
              "`#{dep.name}` is not declared. #{dep.why}",
              "add #{Stack.to_source(dep)}"
            )
          ]

        :error ->
          [
            info(
              :stack_deps,
              "`#{dep.name}` is not declared (#{dep.tier}). #{dep.why}",
              "add #{Stack.to_source(dep)}"
            )
          ]

        {:ok, nil} ->
          []

        {:ok, requirement} ->
          case Stack.check_requirement(dep.name, requirement) do
            :ok ->
              []

            {:stale, expected} ->
              [
                warning(
                  :stack_deps,
                  "`#{dep.name}` is declared as `#{requirement}`, which cannot admit " <>
                    "#{expected}. The app is pinned behind the stack.",
                  "widen to #{expected}"
                )
              ]

            {:invalid, requirement} ->
              [
                warning(
                  :stack_deps,
                  "`#{dep.name}` has an unparseable requirement `#{requirement}`"
                )
              ]
          end
      end
    end)
  end

  defp normalize_dep({name, requirement}) when is_binary(requirement), do: {name, requirement}

  defp normalize_dep({name, requirement, _opts}) when is_binary(requirement),
    do: {name, requirement}

  defp normalize_dep({name, _opts}), do: {name, nil}
  defp normalize_dep(name) when is_atom(name), do: {name, nil}

  @doc """
  Checks a generated `defdo_compiled_config.exs` for the drift that matters.

  Five variants of this file exist across the estate. Two of them return
  `[type: :timestamptz]` from `migration_primary_key/1` and
  `migration_foreign_key/1` where the generator emits `[type: :binary_id]` —
  every migration written against those two builds primary and foreign keys of
  the wrong type.
  """
  @spec check_compiled_config(String.t()) :: [finding()]
  def check_compiled_config(config_path) do
    config_path
    |> compiled_config_files()
    |> Enum.flat_map(fn {path, source} ->
      for fun <- ~w(migration_primary_key migration_foreign_key),
          type = declared_key_type(source, fun),
          type not in [nil, ":binary_id"] do
        error(
          :compiled_config,
          "#{path}: `#{fun}/1` returns `[type: #{type}]`, but the defdo repo flavour is " <>
            "`[type: :binary_id]`. Every migration generated against this file builds keys " <>
            "of the wrong type.",
          "mix defdo.repo.compiled_config --check"
        )
      end
    end)
  end

  defp compiled_config_files(config_path) do
    case File.ls(config_path) do
      {:ok, entries} ->
        for entry <- Enum.sort(entries),
            String.ends_with?(entry, ".exs"),
            path = Path.join(config_path, entry),
            source = File.read!(path),
            source =~ "Defdo.Repo.CompileConfig",
            do: {path, source}

      {:error, _reason} ->
        []
    end
  end

  defp declared_key_type(source, fun) do
    case Regex.run(~r/def\s+#{fun}\([^)]*\).*?\[type:\s*(:\w+)\]/s, source) do
      [_all, type] -> type
      nil -> nil
    end
  end

  @doc """
  Validates an OAuth client's shape, if one was supplied.
  """
  @spec check_oauth(map() | nil, OAuthClient.role()) :: [finding()]
  def check_oauth(nil, _role), do: []

  def check_oauth(client, role) when is_map(client) do
    case OAuthClient.validate(client, role) do
      :ok ->
        [info(:oauth_client, "client shape matches #{role}: #{OAuthClient.describe(role)}")]

      {:error, findings} ->
        for f <- findings do
          %{
            check: :oauth_client,
            severity: f.severity,
            message: f.message,
            remedy: OAuthClient.registration_command(role, name: "<app>") |> String.trim()
          }
        end
    end
  end

  @doc """
  The exit status a CI job should take from a finding list.

  Errors always fail. Warnings fail only under `strict: true`.

      iex> Defdo.Tasks.Saas.Audit.exit_status([])
      0
  """
  @spec exit_status([finding()], keyword()) :: 0 | 1
  def exit_status(findings, opts \\ []) do
    strict? = Keyword.get(opts, :strict, false)
    fail_on = if strict?, do: [:error, :warning], else: [:error]

    if Enum.any?(findings, &(&1.severity in fail_on)), do: 1, else: 0
  end

  defp error(check, message, remedy),
    do: %{check: check, severity: :error, message: message, remedy: remedy}

  defp warning(check, message, remedy \\ nil),
    do: %{check: check, severity: :warning, message: message, remedy: remedy}

  defp info(check, message, remedy \\ nil),
    do: %{check: check, severity: :info, message: message, remedy: remedy}
end

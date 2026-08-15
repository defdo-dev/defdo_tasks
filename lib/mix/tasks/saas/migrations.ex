if match?({:module, _}, Code.ensure_compiled(Igniter.Mix.Task)) do
  defmodule Mix.Tasks.Defdo.Saas.Migrations do
    @shortdoc "Generates the tenant migrator wrapper an app is missing"

    @moduledoc """
    Writes the `Defdo.Tenant.Migrator` wrapper migration this app needs.

        mix defdo.saas.migrations
        mix defdo.saas.migrations --prefix my_app --version 4

    ## The problem this solves

    `Defdo.Tenant.Migrator` versions 1..3 reach most defdo apps indirectly:
    `defdo_vault`'s own version modules chain them, so an app that runs the vault
    migrations gets tenant tables without ever writing a wrapper. Nothing chains
    v4. An app that adopts defdo_tenant 0.11+ therefore has a `tenant_profiles`
    table with no `deleted_at` column and a schema that selects one, and every
    profile read fails with `column t0.deleted_at does not exist`.

    Three apps in the estate hit exactly that and each was repaired by hand, so
    three hand-written wrappers exist and no two of them are the same. This task
    writes one shape.

    ## What it writes

    A migration pinned on both sides to an explicit version. Never floating —
    a wrapper with no `version:` applies whatever schema the installed package
    happens to be at when it first runs, so environments diverge silently. Never
    asymmetric — `down/1` rolls back down to *and including* the version given,
    so a `down` lower than its `up` reverts steps the migration never applied.

    Safe to re-run: if the app already carries a wrapper at the target version,
    nothing is written.

    ## Options

      * `--prefix` — the schema prefix, defaults to the OTP app name
      * `--version` — the migrator version to target, defaults to the highest
        version `Defdo.Tenant.Migrator` actually has
      * `--migrations-path` — defaults to `priv/repo/migrations`
    """

    use Igniter.Mix.Task

    alias Defdo.Tasks.Saas.MigratorChain
    alias Igniter.Project.Application, as: IgniterApp
    alias Igniter.Project.Module, as: IgniterModule

    @impl Igniter.Mix.Task
    def supports_umbrella?, do: false

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :defdo,
        schema: [prefix: :string, version: :integer, migrations_path: :string],
        example: "mix defdo.saas.migrations --prefix my_app"
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      app_name = IgniterApp.app_name(igniter)
      app_module = IgniterModule.module_name_prefix(igniter)
      prefix = options[:prefix] || to_string(app_name)
      migrations_path = options[:migrations_path] || Path.join(["priv", "repo", "migrations"])

      {target, igniter} = resolve_version(igniter, options[:version])

      wrappers = wrappers(igniter, migrations_path)

      igniter
      |> warn_on_asymmetry(wrappers)
      |> warn_on_prefix_conflict(wrappers, prefix)
      |> write_wrapper(wrappers, target, app_module, prefix, migrations_path)
    end

    # Files on disk plus files another task staged earlier in this same Igniter
    # run. Reading only from disk is how a composed installer ends up writing a
    # second wrapper next to the one it just generated.
    defp wrappers(igniter, migrations_path) do
      staged =
        igniter.rewrite
        |> Rewrite.sources()
        |> Enum.map(&{Rewrite.Source.get(&1, :path), Rewrite.Source.get(&1, :content)})
        |> Enum.filter(fn {path, _content} ->
          is_binary(path) and String.ends_with?(path, ".exs") and
            String.contains?(path, migrations_path)
        end)
        |> Enum.map(fn {path, content} -> {Path.basename(path), content} end)

      on_disk =
        case File.ls(migrations_path) do
          {:ok, entries} ->
            for entry <- entries,
                String.ends_with?(entry, ".exs"),
                do: {entry, File.read!(Path.join(migrations_path, entry))}

          {:error, _reason} ->
            []
        end

      (on_disk ++ staged)
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.sort_by(&elem(&1, 0))
      |> MigratorChain.scan()
    end

    defp resolve_version(igniter, nil) do
      case MigratorChain.target_version() do
        {:ok, version} ->
          {version, igniter}

        {:assumed, version} ->
          {version,
           Igniter.add_warning(
             igniter,
             """
             `Defdo.Tenant.Migrator` is not loadable, so this generated a wrapper for v#{version},
             the last version defdo_tasks knows about, rather than reading the version you have
             installed. Run `mix deps.get && mix compile` first, or pass `--version`, if
             defdo_tenant has moved past v#{version}.
             """
           )}
      end
    end

    defp resolve_version(igniter, version) when is_integer(version), do: {version, igniter}

    defp warn_on_asymmetry(igniter, wrappers) do
      Enum.reduce(MigratorChain.asymmetric(wrappers), igniter, fn w, acc ->
        Igniter.add_warning(acc, """
        #{w.file} runs `up(version: #{w.up})` but `down(version: #{w.down})`.

        `Defdo.Migrations.down/1` rolls back down to *and including* the version given, so
        rolling this migration back would revert #{w.up - w.down} step(s) it never applied.
        Change its `down` to `version: #{w.up}`.
        """)
      end)
    end

    defp warn_on_prefix_conflict(igniter, wrappers, prefix) do
      Enum.reduce(MigratorChain.prefix_conflicts(wrappers, prefix), igniter, fn w, acc ->
        Igniter.add_warning(acc, """
        #{w.file} creates the tenant tables in the "#{w.prefix}" schema, not "#{prefix}".

        Two wrappers with different prefixes do not fail -- they build two independent copies
        of `tenant_profiles`, and which one the app reads depends on the repo's `search_path`.
        `mix defdo_tenant.install` writes "defdo_tenant" as its prefix and does not accept a
        `--prefix` override (the switch is documented but missing from its Igniter schema), so
        this is what you get when the two installers are composed.

        Pick one schema. If "#{prefix}" is the one you want, edit #{w.file} to use it before
        running `mix ecto.migrate` -- after the migration has run, moving it is a data
        migration rather than an edit.
        """)
      end)
    end

    defp write_wrapper(igniter, wrappers, target, app_module, prefix, migrations_path) do
      cond do
        floating = Enum.find(wrappers, &(&1.up == :floating)) ->
          Igniter.add_warning(igniter, """
          #{floating.file} calls `Defdo.Tenant.Migrator.up/1` with no `version:`.

          Its behaviour is pinned to whichever defdo_tenant is installed the first time it runs,
          so a fresh database and a migrated one end up on different schemas. Pin it explicitly
          before generating anything on top of it -- otherwise the wrapper written here and that
          one will disagree about what has already been applied.
          """)

        MigratorChain.applied_version(wrappers) >= target ->
          Igniter.add_notice(
            igniter,
            "Tenant migrator wrapper is already at v#{target}. Nothing to write."
          )

        true ->
          path =
            Path.join(
              migrations_path,
              MigratorChain.filename(target, taken: MigratorChain.taken_stamps(migrations_path))
            )

          igniter
          |> Igniter.create_new_file(path, MigratorChain.render(app_module, target, prefix))
          |> Igniter.add_notice("""
          Wrote the tenant migrator wrapper for v#{target} (prefix "#{prefix}").

          Run `mix ecto.migrate` to apply it. Without it, `tenant_profiles` has no `deleted_at`
          column and every profile read against defdo_tenant 0.11+ fails.
          """)
      end
    end
  end
else
  defmodule Mix.Tasks.Defdo.Saas.Migrations do
    @shortdoc "Generates the tenant migrator wrapper an app is missing (requires Igniter)"
    @moduledoc """
    Requires Igniter. Add it and re-run:

        {:igniter, "~> 0.6 or ~> 0.7 or ~> 0.8", only: [:dev, :test]}
    """

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      mix defdo.saas.migrations requires Igniter.

      Add `{:igniter, "~> 0.6 or ~> 0.7 or ~> 0.8", only: [:dev, :test]}` to your deps,
      run `mix deps.get`, and try again.

      To audit the migrator chain without Igniter, run `mix defdo.saas.doctor` instead.
      """)

      exit({:shutdown, 1})
    end
  end
end

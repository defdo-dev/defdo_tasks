defmodule Mix.Tasks.Defdo.Saas.MigrationsTest do
  @moduledoc """
  The generator task, run against a real (in-memory) Mix project.

  `Defdo.Tenant.Migrator` is not a dependency of this package, so the target
  version resolves as `{:assumed, 4}` here. That is the honest answer and the
  task says so in a warning; these tests pin the version explicitly where the
  version itself is not what is under test.
  """
  use ExUnit.Case, async: true

  import Igniter.Test

  defp migration_paths(igniter) do
    igniter.rewrite
    |> Rewrite.sources()
    |> Enum.map(&Rewrite.Source.get(&1, :path))
    |> Enum.filter(&String.contains?(&1, "priv/repo/migrations"))
  end

  defp migration_contents(igniter) do
    igniter.rewrite
    |> Rewrite.sources()
    |> Enum.filter(&String.contains?(Rewrite.Source.get(&1, :path), "priv/repo/migrations"))
    |> Enum.map_join("\n", &Rewrite.Source.get(&1, :content))
  end

  test "writes a wrapper pinned on both sides to the same version" do
    igniter =
      test_project()
      |> Igniter.compose_task("defdo.saas.migrations", ["--version", "4", "--prefix", "my_app"])

    assert [path] = migration_paths(igniter)
    assert path =~ ~r/priv\/repo\/migrations\/\d{14}_upgrade_defdo_tenant_migrator_v04\.exs/

    source = migration_contents(igniter)
    assert source =~ "Defdo.Tenant.Migrator.up(version: 4, prefix: @prefix)"
    assert source =~ "Defdo.Tenant.Migrator.down(version: 4, prefix: @prefix)"
    assert source =~ ~s|@prefix "my_app"|
  end

  test "defaults the prefix to the OTP app name" do
    igniter =
      test_project(app_name: :my_saas)
      |> Igniter.compose_task("defdo.saas.migrations", ["--version", "4"])

    assert migration_contents(igniter) =~ ~s|@prefix "my_saas"|
  end

  test "writes nothing when the app is already at the target version" do
    existing = ~S|def up, do: Defdo.Tenant.Migrator.up(version: 4, prefix: "my_app")|

    igniter =
      [{"priv/repo/migrations/20260101000000_wrapper.exs", existing}]
      |> Map.new()
      |> then(&test_project(files: &1))
      |> Igniter.compose_task("defdo.saas.migrations", ["--version", "4", "--prefix", "my_app"])

    assert migration_paths(igniter) == ["priv/repo/migrations/20260101000000_wrapper.exs"]
    assert Enum.any?(igniter.notices, &(&1 =~ "already at v4"))
  end

  test "upgrades an app that stops at v3" do
    existing = ~S|def up, do: Defdo.Tenant.Migrator.up(version: 3, prefix: "my_app")|

    igniter =
      test_project(files: %{"priv/repo/migrations/20260101000000_v3.exs" => existing})
      |> Igniter.compose_task("defdo.saas.migrations", ["--version", "4", "--prefix", "my_app"])

    assert length(migration_paths(igniter)) == 2
    assert migration_contents(igniter) =~ "Defdo.Tenant.Migrator.up(version: 4"
  end

  test "refuses to build on top of a floating wrapper" do
    floating = ~S|def up, do: Defdo.Tenant.Migrator.up(prefix: "my_app")|

    igniter =
      test_project(files: %{"priv/repo/migrations/20260101000000_floating.exs" => floating})
      |> Igniter.compose_task("defdo.saas.migrations", ["--version", "4", "--prefix", "my_app"])

    # Nothing new written -- generating on top of a wrapper whose applied version
    # is unknowable would produce two migrations that disagree about what is done.
    assert migration_paths(igniter) == ["priv/repo/migrations/20260101000000_floating.exs"]
    assert Enum.any?(igniter.warnings, &(&1 =~ "no `version:`"))
  end

  test "warns when an existing wrapper targets a different schema" do
    other_schema = ~S|def up, do: Defdo.Tenant.Migrator.up(version: 4, prefix: "defdo_tenant")|

    igniter =
      test_project(files: %{"priv/repo/migrations/20260101000000_other.exs" => other_schema})
      |> Igniter.compose_task("defdo.saas.migrations", ["--version", "4", "--prefix", "my_app"])

    assert Enum.any?(igniter.warnings, &(&1 =~ "not \"my_app\""))
    assert Enum.any?(igniter.warnings, &(&1 =~ "search_path"))
  end

  test "warns about an asymmetric down it did not write" do
    asymmetric =
      ~S|def up, do: Defdo.Tenant.Migrator.up(version: 4, prefix: "my_app")| <>
        "\n" <> ~S|def down, do: Defdo.Tenant.Migrator.down(version: 1, prefix: "my_app")|

    igniter =
      test_project(files: %{"priv/repo/migrations/20260101000000_asym.exs" => asymmetric})
      |> Igniter.compose_task("defdo.saas.migrations", ["--version", "4", "--prefix", "my_app"])

    assert Enum.any?(igniter.warnings, &(&1 =~ "revert 3 step(s) it never applied"))
  end

  test "says so when it could not read the installed migrator version" do
    igniter = test_project() |> Igniter.compose_task("defdo.saas.migrations", [])

    assert Enum.any?(igniter.warnings, &(&1 =~ "not loadable"))
  end
end

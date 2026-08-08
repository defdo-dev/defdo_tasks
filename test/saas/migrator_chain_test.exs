defmodule Defdo.Tasks.Saas.MigratorChainTest do
  use ExUnit.Case, async: true

  alias Defdo.Tasks.Saas.MigratorChain

  doctest MigratorChain

  # The three wrappers that were written by hand in this estate, verbatim enough
  # to prove the scanner reads real files rather than a shape invented for the
  # test. They differ in exactly the ways that matter: literal vs computed
  # prefix, and whether `down` matches `up`.
  @status_wrapper ~S'''
  defmodule Defdo.Status.Repo.Migrations.UpgradeDefdoTenantMigratorV04 do
    use Ecto.Migration

    @prefix "defdo_status"

    def up do
      Defdo.Tenant.Migrator.up(version: 4, prefix: @prefix)
    end

    def down do
      Defdo.Tenant.Migrator.down(version: 4, prefix: @prefix)
    end
  end
  '''

  @cms_wrapper ~S'''
  defmodule Defdo.Cms.Repo.Migrations.UpgradeDefdoTenantToV04 do
    use Ecto.Migration

    def up,
      do: Defdo.Tenant.Migrator.up(version: 4, prefix: Defdo.Cms.Config.migration_default_prefix())

    def down,
      do:
        Defdo.Tenant.Migrator.down(version: 4, prefix: Defdo.Cms.Config.migration_default_prefix())
  end
  '''

  @auth_wrapper ~S'''
  defmodule Defdo.Auth.Repo.Migrations.UpgradeDefdoTenantMigratorV04 do
    use Ecto.Migration

    @prefix "defdo_auth"

    def up do
      Defdo.Tenant.Migrator.up(version: 4, prefix: @prefix)
    end

    def down do
      Defdo.Tenant.Migrator.down(version: 3, prefix: @prefix)
    end
  end
  '''

  # The one nobody wrote: defdo_order still pins v3, and its requirement admits
  # defdo_tenant 0.11+, so it is the app most exposed to the failure.
  @order_wrapper ~S'''
  defmodule Defdo.Order.Repo.Migrations.AddTenantScopedOrderPersistence do
    use Ecto.Migration

    @tenant_prefix "defdo_order"

    def up do
      Defdo.Tenant.Migrator.up(version: 3, prefix: @tenant_prefix)
    end

    def down do
      Defdo.Tenant.Migrator.down(version: 1, prefix: @tenant_prefix)
    end
  end
  '''

  # defdo_wa_service: no `version:` at all. What this applies depends on which
  # defdo_tenant is installed the first time it runs.
  @wa_service_wrapper ~S'''
  defmodule Defdo.WaService.Repo.Migrations.InstallDefdoTenant do
    use Ecto.Migration

    def up, do: Defdo.Tenant.Migrator.up(prefix: Defdo.WaService.RepoConfig.schema())
    def down, do: Defdo.Tenant.Migrator.down(prefix: Defdo.WaService.RepoConfig.schema())
  end
  '''

  describe "scan/2" do
    test "reads a literal @prefix wrapper" do
      assert [wrapper] = MigratorChain.scan([{"status.exs", @status_wrapper}])
      assert wrapper.up == 4
      assert wrapper.down == 4
      assert wrapper.prefix == "defdo_status"
    end

    test "reports a computed prefix as :dynamic rather than guessing" do
      assert [wrapper] = MigratorChain.scan([{"cms.exs", @cms_wrapper}])
      assert wrapper.up == 4
      assert wrapper.prefix == :dynamic
    end

    test "reads a call with no version: as floating" do
      assert [wrapper] = MigratorChain.scan([{"wa.exs", @wa_service_wrapper}])
      assert wrapper.up == :floating
      assert wrapper.down == :floating
    end

    test "ignores migrations that do not touch the tenant migrator" do
      assert MigratorChain.scan([{"other.exs", "def up, do: create table(:things)"}]) == []
    end

    test "does not confuse another package's migrator for this one" do
      source = ~S|def up, do: Defdo.Vault.Migrator.up(version: 10, prefix: "app")|
      assert MigratorChain.scan([{"vault.exs", source}]) == []
      assert [_] = MigratorChain.scan([{"vault.exs", source}], "Defdo.Vault.Migrator")
    end
  end

  describe "status/2" do
    test "an app that stops at v3 is behind, which is the failure being prevented" do
      wrappers = MigratorChain.scan([{"order.exs", @order_wrapper}])
      assert MigratorChain.status(wrappers, 4) == {:behind, 3, 4}
    end

    test "an app with the v4 wrapper is current" do
      wrappers = MigratorChain.scan([{"status.exs", @status_wrapper}])
      assert MigratorChain.status(wrappers, 4) == :current
    end

    test "an app with no wrapper at all is missing" do
      assert MigratorChain.status([], 4) == {:missing, 4}
    end

    test "a floating wrapper outranks being behind" do
      wrappers =
        MigratorChain.scan([{"order.exs", @order_wrapper}, {"wa.exs", @wa_service_wrapper}])

      assert {:floating, ["wa.exs"]} = MigratorChain.status(wrappers, 4)
    end

    test "an app past the target version is current, not broken" do
      source = ~S|def up, do: Defdo.Tenant.Migrator.up(version: 7, prefix: "app")|
      assert MigratorChain.status(MigratorChain.scan([{"a.exs", source}]), 4) == :current
    end
  end

  describe "asymmetric/1" do
    test "catches the wrapper that rolls back a step it never applied" do
      wrappers = MigratorChain.scan([{"auth.exs", @auth_wrapper}])
      assert [%{file: "auth.exs", up: 4, down: 3}] = MigratorChain.asymmetric(wrappers)
    end

    test "a matched pair is not asymmetric" do
      wrappers = MigratorChain.scan([{"status.exs", @status_wrapper}])
      assert MigratorChain.asymmetric(wrappers) == []
    end

    test "a floating wrapper is not reported as asymmetric -- it has a worse problem" do
      wrappers = MigratorChain.scan([{"wa.exs", @wa_service_wrapper}])
      assert MigratorChain.asymmetric(wrappers) == []
    end
  end

  describe "prefix_conflicts/2" do
    test "catches the two-schema split the composed installers produce" do
      tenant_installer =
        ~S|def up, do: Defdo.Tenant.Migrator.up(version: 4, prefix: "defdo_tenant")|

      wrappers =
        MigratorChain.scan([{"a.exs", tenant_installer}, {"b.exs", @status_wrapper}])

      assert [%{file: "a.exs"}] = MigratorChain.prefix_conflicts(wrappers, "defdo_status")
    end

    test "a dynamic prefix is never reported, because it cannot be compared" do
      wrappers = MigratorChain.scan([{"cms.exs", @cms_wrapper}])
      assert MigratorChain.prefix_conflicts(wrappers, "anything") == []
    end
  end

  describe "target_version/1" do
    test "reports assumed when the migrator is not loadable" do
      assert {:assumed, version} = MigratorChain.target_version("No.Such.Migrator")
      assert version >= 4
    end

    test "probes version modules when the migrator is loadable" do
      # Defdo.Tasks.TestMigrator (test/support) declares V01..V03 and no V04.
      assert MigratorChain.target_version("Defdo.Tasks.TestMigrator") == {:ok, 3}
    end
  end

  describe "resolve_target/2" do
    @migrator_source ~S'''
    defmodule Defdo.Tenant.Migrator do
      use Defdo.Migrator,
        control_table: "tenant_profiles",
        prefix: "defdo_tenant",
        current_version: 4
    end
    '''

    @tag :tmp_dir
    test "reads current_version from the resolved deps migrator source", %{tmp_dir: tmp_dir} do
      dep = Path.join([tmp_dir, "deps", "defdo_tenant"])
      File.mkdir_p!(Path.join(dep, "lib/defdo"))
      File.write!(Path.join(dep, "lib/defdo/migrator.ex"), @migrator_source)
      File.write!(Path.join(dep, "VERSION"), "0.13.0")

      resolution = MigratorChain.resolve_target(tmp_dir)

      assert resolution.version == 4
      assert resolution.source == :deps
      assert resolution.confidence == :resolved
      assert resolution.dependency == :defdo_tenant
      assert resolution.dependency_version == "0.13.0"
    end

    @tag :tmp_dir
    test "reads a path:-resolved dependency from :package_path", %{tmp_dir: tmp_dir} do
      pkg = Path.join(tmp_dir, "defdo_tenant_checkout")
      File.mkdir_p!(Path.join(pkg, "lib/defdo"))
      File.write!(Path.join(pkg, "lib/defdo/migrator.ex"), @migrator_source)
      File.write!(Path.join(pkg, "VERSION"), "0.13.1")

      resolution = MigratorChain.resolve_target(tmp_dir, package_path: pkg)

      assert resolution.version == 4
      assert resolution.source == :deps
      assert resolution.dependency_version == "0.13.1"
    end

    @tag :tmp_dir
    test "falls back to mix.lock when deps are absent", %{tmp_dir: tmp_dir} do
      File.write!(
        Path.join(tmp_dir, "mix.lock"),
        ~s|  "defdo_tenant": {:hex, :defdo_tenant, "0.10.5", "abc", [:mix], [], "hexpm:defdo"},\n|
      )

      resolution = MigratorChain.resolve_target(tmp_dir)

      assert resolution.version == 3
      assert resolution.source == :lock
      assert resolution.confidence == :from_lock
      assert resolution.dependency_version == "0.10.5"
    end

    @tag :tmp_dir
    test "assumes only when neither deps nor lock can be read", %{tmp_dir: tmp_dir} do
      resolution = MigratorChain.resolve_target(tmp_dir)

      assert resolution.source == :assumed
      assert resolution.confidence == :assumed
      assert resolution.dependency_version == nil
      assert resolution.reason =~ "not a reading"
    end
  end

  describe "render/3" do
    test "pins up and down to the same explicit version" do
      source = MigratorChain.render(MyApp, 4, "my_app")

      assert source =~ ~s|Defdo.Tenant.Migrator.up(version: 4, prefix: @prefix)|
      assert source =~ ~s|Defdo.Tenant.Migrator.down(version: 4, prefix: @prefix)|
      assert source =~ ~s|@prefix "my_app"|
    end

    test "what it renders scans back as current and symmetric" do
      wrappers = MigratorChain.scan([{"generated.exs", MigratorChain.render(MyApp, 4, "my_app")}])

      assert MigratorChain.status(wrappers, 4) == :current
      assert MigratorChain.asymmetric(wrappers) == []
      assert MigratorChain.prefix_conflicts(wrappers, "my_app") == []
    end

    test "it is valid Elixir" do
      source = MigratorChain.render(MyApp, 4, "my_app")
      assert {:ok, _ast} = Code.string_to_quoted(source)
    end
  end

  describe "filename/2" do
    test "sorts after an earlier migration and names its version" do
      now = ~U[2026-08-07 12:00:00Z]
      name = MigratorChain.filename(4, now: now, suffix: "001")

      assert name == "20260807120000001_upgrade_defdo_tenant_migrator_v04.exs"
    end

    test "two wrappers generated in the same second do not collide" do
      now = ~U[2026-08-07 12:00:00Z]
      names = for _ <- 1..25, do: MigratorChain.filename(4, now: now)

      assert length(Enum.uniq(names)) == 25
    end
  end

  describe "scan_path/2" do
    test "a missing directory scans as empty rather than raising" do
      assert MigratorChain.scan_path("/nonexistent/priv/repo/migrations") == []
    end

    @tag :tmp_dir
    test "reads real files from disk", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "20260101000000_wrapper.exs"), @status_wrapper)
      File.write!(Path.join(tmp_dir, "notes.md"), "not a migration")

      assert [%{file: "20260101000000_wrapper.exs", up: 4}] = MigratorChain.scan_path(tmp_dir)
    end
  end
end

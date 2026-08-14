defmodule Defdo.Tasks.Saas.AuditTest do
  use ExUnit.Case, async: true

  alias Defdo.Tasks.Saas.Audit

  doctest Audit

  defp checks(findings, check), do: Enum.filter(findings, &(&1.check == check))
  defp errors(findings), do: Enum.filter(findings, &(&1.severity == :error))

  defp write_migration(dir, name, source) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), source)
  end

  describe "check_migrator_chain/1" do
    @tag :tmp_dir
    test "an app with no wrapper is told what will break and how", %{tmp_dir: tmp_dir} do
      findings = Audit.check_migrator_chain(Path.join(tmp_dir, "migrations"))

      assert [finding] = findings |> checks(:migrator_chain) |> errors()
      assert finding.message =~ "deleted_at does not exist"
      assert finding.remedy == "mix defdo.saas.migrations"
    end

    @tag :tmp_dir
    test "an app pinned at v3 is reported as behind", %{tmp_dir: tmp_dir} do
      write_migration(
        tmp_dir,
        "20260525013349_add_tenant_scoped_order_persistence.exs",
        ~S|def up, do: Defdo.Tenant.Migrator.up(version: 3, prefix: "defdo_order")|
      )

      assert [finding] =
               tmp_dir |> Audit.check_migrator_chain() |> checks(:migrator_chain) |> errors()

      assert finding.message =~ "stops at v3"
    end

    @tag :tmp_dir
    test "an app at the current version reports no error", %{tmp_dir: tmp_dir} do
      write_migration(
        tmp_dir,
        "20260806120000_upgrade_defdo_tenant_migrator_v04.exs",
        ~S|def up, do: Defdo.Tenant.Migrator.up(version: 4, prefix: "app")| <>
          "\n" <> ~S|def down, do: Defdo.Tenant.Migrator.down(version: 4, prefix: "app")|
      )

      findings = Audit.check_migrator_chain(tmp_dir)

      assert errors(findings) == []
    end

    @tag :tmp_dir
    test "a version-less wrapper is an error, not a warning", %{tmp_dir: tmp_dir} do
      write_migration(
        tmp_dir,
        "20260607052100_install_defdo_tenant.exs",
        ~S|def up, do: Defdo.Tenant.Migrator.up(prefix: Defdo.WaService.RepoConfig.schema())|
      )

      assert [finding] =
               tmp_dir |> Audit.check_migrator_chain() |> checks(:migrator_chain) |> errors()

      assert finding.message =~ "no\n`version:`" or finding.message =~ "no `version:`"
      assert finding.message =~ "diverge"
    end

    @tag :tmp_dir
    test "an asymmetric down is reported with the exact fix", %{tmp_dir: tmp_dir} do
      write_migration(
        tmp_dir,
        "20260806150000_upgrade_defdo_tenant_migrator_v04.exs",
        ~S|def up, do: Defdo.Tenant.Migrator.up(version: 4, prefix: "defdo_auth")| <>
          "\n" <> ~S|def down, do: Defdo.Tenant.Migrator.down(version: 3, prefix: "defdo_auth")|
      )

      assert [finding] = tmp_dir |> Audit.check_migrator_chain() |> checks(:migrator_rollback)
      assert finding.severity == :warning
      assert finding.remedy == "change `down` to version: 4"
    end

    @tag :tmp_dir
    test "wrappers that disagree about the schema prefix are an error", %{tmp_dir: tmp_dir} do
      write_migration(
        tmp_dir,
        "20260101000000_install_defdo_tenant.exs",
        ~S|def up, do: Defdo.Tenant.Migrator.up(version: 4, prefix: "defdo_tenant")|
      )

      write_migration(
        tmp_dir,
        "20260101000001_upgrade_defdo_tenant_migrator_v04.exs",
        ~S|def up, do: Defdo.Tenant.Migrator.up(version: 4, prefix: "my_app")|
      )

      assert [finding] = tmp_dir |> Audit.check_migrator_chain() |> checks(:migrator_prefix)
      assert finding.severity == :error
      assert finding.message =~ "search_path"
    end
  end

  describe "check_deps/1" do
    test "every missing core package is an error naming the line to add" do
      findings = [] |> Audit.check_deps() |> checks(:stack_deps) |> errors()

      assert length(findings) == 4

      assert Enum.any?(
               findings,
               &(&1.remedy == ~s(add {:defdo_tenant, "~> 0.12", organization: :defdo}))
             )

      assert Enum.any?(
               findings,
               &(&1.remedy == ~s(add {:defdo_vault, "~> 0.10", organization: :defdo}))
             )
    end

    test "a full core stack produces no errors" do
      deps = [
        {:defdo_tenant, "~> 0.12", organization: :defdo},
        {:defdo_tenant_plug, "~> 0.2", organization: :defdo},
        {:defdo_tenant_boundary, "~> 0.2", organization: :defdo},
        {:defdo_vault, "~> 0.10", organization: :defdo}
      ]

      assert Audit.check_deps(deps) |> errors() == []
    end

    test "a requirement that cannot admit the current Hex release is a warning" do
      deps = [
        {:defdo_tenant, "~> 0.10.5", organization: :defdo},
        {:defdo_tenant_plug, "~> 0.2"},
        {:defdo_tenant_boundary, "~> 0.2"},
        {:defdo_vault, "~> 0.10"},
        {:defdo_payments, "~> 0.3"}
      ]

      hex_baseline = %{defdo_tenant: {:ok, Version.parse!("0.13.0")}}

      assert [finding] =
               deps |> Audit.check_deps(hex_baseline) |> Enum.filter(&(&1.severity == :warning))

      assert finding.message =~ "pinned behind the stack"
      assert finding.message =~ "0.13.0"
      assert finding.remedy == "widen to ~> 0.13"
    end

    test "a requirement ahead of the current Hex release is a note, not a warning" do
      # This is the bug made visible: the app ships defdo_tenant 0.13, the
      # doctor's own (now-live) baseline has only seen 0.12 published. The
      # app is ahead, not "pinned behind the stack" -- so this must never be
      # a warning, let alone one recommending a downgrade.
      deps = [
        {:defdo_tenant, "~> 0.13", organization: :defdo},
        {:defdo_tenant_plug, "~> 0.2"},
        {:defdo_tenant_boundary, "~> 0.2"},
        {:defdo_vault, "~> 0.10"},
        {:defdo_payments, "~> 0.3"}
      ]

      hex_baseline = %{defdo_tenant: {:ok, Version.parse!("0.12.0")}}

      findings = Audit.check_deps(deps, hex_baseline)

      refute Enum.any?(findings, &(&1.severity == :warning))

      assert [finding] =
               Enum.filter(findings, &(&1.check == :stack_deps and &1.severity == :info))

      assert finding.message =~ "ahead of what Hex has published"
    end

    test "an unresolved baseline entry is a note, and asserts nothing about the pin" do
      deps = [
        {:defdo_tenant, "~> 0.13", organization: :defdo},
        {:defdo_tenant_plug, "~> 0.2"},
        {:defdo_tenant_boundary, "~> 0.2"},
        {:defdo_vault, "~> 0.10"},
        {:defdo_payments, "~> 0.3"}
      ]

      hex_baseline = %{defdo_tenant: {:error, :timeout}}

      findings = Audit.check_deps(deps, hex_baseline)

      refute Enum.any?(findings, &(&1.severity in [:warning, :error]))

      assert [finding] =
               Enum.filter(findings, &(&1.check == :stack_deps and &1.severity == :info))

      assert finding.message =~ "could not resolve"
      assert finding.message =~ "defdo_tenant"
    end

    test "a package absent from the baseline map is silently out of scope" do
      # No `:hex_baseline` entry at all (the default `%{}`) must not produce
      # a finding of its own -- that is reserved for a resolution that was
      # actually attempted and failed.
      deps = [
        {:defdo_tenant, "~> 0.13", organization: :defdo},
        {:defdo_tenant_plug, "~> 0.2"},
        {:defdo_tenant_boundary, "~> 0.2"},
        {:defdo_vault, "~> 0.10"},
        {:defdo_payments, "~> 0.3"}
      ]

      assert Audit.check_deps(deps) == []
    end

    test "handles every dep tuple shape mix.exs allows" do
      deps = [
        :defdo_tenant,
        {:defdo_tenant_plug, path: "../defdo_tenant_plug"},
        {:defdo_tenant_boundary, "~> 0.2"},
        {:defdo_vault, "~> 0.10", organization: :defdo}
      ]

      assert Audit.check_deps(deps) |> errors() == []
    end

    test "a missing recommended package is a note, not an error" do
      deps = [
        {:defdo_tenant, "~> 0.12"},
        {:defdo_tenant_plug, "~> 0.2"},
        {:defdo_tenant_boundary, "~> 0.2"},
        {:defdo_vault, "~> 0.10"}
      ]

      assert [finding] = deps |> Audit.check_deps() |> Enum.filter(&(&1.severity == :info))
      assert finding.message =~ "defdo_payments"
    end
  end

  describe "check_compiled_config/1" do
    @tag :tmp_dir
    test "catches the timestamptz key bug that two apps carry", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "defdo_compiled_config.exs"), ~S'''
      defmodule Defdo.Repo.CompileConfig do
        def migration_primary_key(extras \\ []) when is_list(extras), do: [type: :timestamptz] ++ extras
        def migration_foreign_key(extras \\ []) when is_list(extras), do: [type: :timestamptz] ++ extras
      end
      ''')

      findings = Audit.check_compiled_config(tmp_dir)

      assert length(findings) == 2
      assert Enum.all?(findings, &(&1.severity == :error))
      assert Enum.any?(findings, &(&1.message =~ "migration_primary_key"))
      assert Enum.any?(findings, &(&1.message =~ "migration_foreign_key"))
    end

    @tag :tmp_dir
    test "a correct flavour file is clean", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "defdo_compiled_config.exs"), ~S'''
      defmodule Defdo.Repo.CompileConfig do
        def migration_primary_key(extras \\ []) when is_list(extras), do: [type: :binary_id] ++ extras
        def migration_foreign_key(extras \\ []) when is_list(extras), do: [type: :binary_id] ++ extras
        def migration_timestamps(extras \\ []) when is_list(extras), do: [type: :timestamptz] ++ extras
      end
      ''')

      assert Audit.check_compiled_config(tmp_dir) == []
    end

    @tag :tmp_dir
    test "ignores config files that are not the flavour file", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.exs"), "import Config\n")

      assert Audit.check_compiled_config(tmp_dir) == []
    end

    test "a missing config directory is not a finding" do
      assert Audit.check_compiled_config("/nonexistent/config") == []
    end
  end

  describe "check_oauth/2" do
    test "no client supplied means nothing to check" do
      assert Audit.check_oauth(nil, :instance_service) == []
    end

    test "a bad shape carries the registration command as its remedy" do
      client = %{supported_grant_types: ["refresh_token", "revoke"], confidential: true}

      assert [finding | _] = Audit.check_oauth(client, :instance_service)
      assert finding.severity == :error
      assert finding.remedy =~ "client_credentials,introspect"
    end
  end

  describe "exit_status/2" do
    test "errors fail the build" do
      findings = [%{check: :x, severity: :error, message: "m", remedy: nil}]
      assert Audit.exit_status(findings) == 1
    end

    test "warnings pass by default and fail under strict" do
      findings = [%{check: :x, severity: :warning, message: "m", remedy: nil}]

      assert Audit.exit_status(findings) == 0
      assert Audit.exit_status(findings, strict: true) == 1
    end

    test "notes never fail, even under strict" do
      findings = [%{check: :x, severity: :info, message: "m", remedy: nil}]

      assert Audit.exit_status(findings, strict: true) == 0
    end
  end

  describe "run/2" do
    @tag :tmp_dir
    test "composes every check against one project root", %{tmp_dir: tmp_dir} do
      findings = Audit.run(tmp_dir, deps: [])

      assert Enum.any?(findings, &(&1.check == :migrator_chain))
      assert Enum.any?(findings, &(&1.check == :stack_deps))
    end
  end
end

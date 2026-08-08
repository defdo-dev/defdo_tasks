defmodule Defdo.Tasks.MCP.ServerTest do
  use ExUnit.Case, async: true

  alias Defdo.Tasks.MCP.Server
  alias Defdo.Tasks.Saas.{MigratorChain, Stack}

  defp state, do: Server.new()

  defp call(id, tool, arguments \\ %{}, state \\ state()) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => tool, "arguments" => arguments}
    }

    Server.handle_message(request, state)
  end

  defp decode_tool_payload(response) do
    response
    |> get_in(["result", "content"])
    |> List.first()
    |> Map.fetch!("text")
    |> Jason.decode!()
  end

  defp write_migration(dir, name, source) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), source)
  end

  # Writes a fake resolved defdo_tenant dependency under a root, so the
  # migrator_chain tool resolves a target from `:deps` rather than assuming one.
  defp write_tenant_dep(root, current_version, version) do
    dep_dir = Path.join([root, "deps", "defdo_tenant"])
    File.mkdir_p!(Path.join(dep_dir, "lib/defdo"))

    File.write!(
      Path.join(dep_dir, "lib/defdo/migrator.ex"),
      """
      defmodule Defdo.Tenant.Migrator do
        use Defdo.Migrator,
          control_table: "tenant_profiles",
          prefix: "defdo_tenant",
          current_version: #{current_version}
      end
      """
    )

    File.write!(Path.join(dep_dir, "VERSION"), version)
  end

  defp write_lock(root, package, version) do
    File.write!(
      Path.join(root, "mix.lock"),
      ~s|  "#{package}": {:hex, :#{package}, "#{version}", "abc", [:mix], [], "hexpm:defdo"},\n|
    )
  end

  test "responds to initialize" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{"protocolVersion" => "2025-06-18"}
    }

    {response, _state} = Server.handle_message(request, state())

    assert response["id"] == 1
    assert response["result"]["protocolVersion"] == "2025-06-18"
    assert response["result"]["capabilities"]["tools"]
    assert response["result"]["serverInfo"]["name"] == "defdo_tasks"

    assert response["result"]["serverInfo"]["version"] ==
             Application.spec(:defdo_tasks, :vsn) |> to_string()
  end

  test "lists exactly the three read-only tools" do
    request = %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}

    {response, _state} = Server.handle_message(request, state())

    names = Enum.map(response["result"]["tools"], & &1["name"])

    assert names == ["defdo_saas.stack", "defdo_saas.migrator_chain", "defdo_saas.audit"]
  end

  test "an unknown method answers -32601" do
    request = %{"jsonrpc" => "2.0", "id" => 9, "method" => "resources/list"}

    {response, _state} = Server.handle_message(request, state())

    assert response["error"]["code"] == -32_601
    assert response["error"]["data"]["method"] == "resources/list"
  end

  describe "tools/call: unknown tool name" do
    test "answers -32602 naming the requested tool" do
      {response, _state} = call(3, "defdo_saas.nope")

      assert response["error"]["code"] == -32_602
      assert response["error"]["message"] == "Unknown tool"
      assert response["error"]["data"]["name"] == "defdo_saas.nope"
    end
  end

  describe "defdo_saas.stack" do
    test "with no arguments returns the default install set" do
      {response, _state} = call(4, "defdo_saas.stack")
      payload = decode_tool_payload(response)

      names = payload["dependencies"] |> Enum.map(& &1["name"])

      assert names == Stack.select() |> Enum.map(&to_string(&1.name))
      assert payload["tiers"] == ["core", "recommended", "optional"]
    end

    test "a dependency carries requirement, tier, hex, published and a remedy source line" do
      {response, _state} = call(5, "defdo_saas.stack")
      payload = decode_tool_payload(response)

      tenant = Enum.find(payload["dependencies"], &(&1["name"] == "defdo_tenant"))

      assert tenant["requirement"] == "~> 0.12"
      assert tenant["tier"] == "core"
      assert tenant["hex"] == true
      assert tenant["published"] == true
      assert tenant["source"] == ~s({:defdo_tenant, "~> 0.12", organization: :defdo})
    end

    test "tiers filters to exactly the tier(s) asked for" do
      {response, _state} = call(6, "defdo_saas.stack", %{"tiers" => ["core"]})
      payload = decode_tool_payload(response)

      assert payload["dependencies"] |> Enum.map(& &1["name"]) ==
               Stack.select([:core]) |> Enum.map(&to_string(&1.name))

      assert Enum.all?(payload["dependencies"], &(&1["tier"] == "core"))
    end

    test "all: true returns Stack.all/0, unfiltered by tier or publish status" do
      {response, _state} = call(7, "defdo_saas.stack", %{"all" => true})
      payload = decode_tool_payload(response)

      assert payload["dependencies"] |> Enum.map(& &1["name"]) ==
               Stack.all() |> Enum.map(&to_string(&1.name))

      # Stack.select/1 excludes this one by default because it is not
      # published; Stack.all/0 (and so `all: true`) does not.
      assert "defdo_tenant_provision" in Enum.map(payload["dependencies"], & &1["name"])
    end

    test "an unknown tier is an error naming the real ones, not an empty list" do
      {response, _state} = call(8, "defdo_saas.stack", %{"tiers" => ["urgent"]})

      assert response["error"]["message"] == "Unknown tier"
      assert response["error"]["data"]["requested"] == ["urgent"]
      assert response["error"]["data"]["tiers"] == ["core", "recommended", "optional"]
    end
  end

  describe "defdo_saas.migrator_chain" do
    @tag :tmp_dir
    test "an assumed target reports unknown, not a confident current/missing",
         %{tmp_dir: tmp_dir} do
      {response, _state} =
        call(10, "defdo_saas.migrator_chain", %{
          "root" => tmp_dir,
          "migrator" => "Defdo.Tenant.Migrator"
        })

      payload = decode_tool_payload(response)

      assert payload["root"] == tmp_dir
      assert payload["migrations_path"] == Path.join([tmp_dir, "priv", "repo", "migrations"])
      assert payload["target_version_source"] == "assumed"
      assert payload["target_version_confidence"] == "assumed"
      assert payload["resolved_version"] == nil
      assert payload["wrappers"] == []
      # Not `missing`: the target was never read, so no status claim rests on it.
      assert payload["status"]["kind"] == "unknown"
      assert payload["status"]["applied"] == 0
      assert payload["status"]["reason"] =~ "not a reading"
      assert payload["asymmetric"] == []
      assert payload["prefix_checked"] == false
      assert payload["prefix_conflicts"] == nil
    end

    @tag :tmp_dir
    test "resolves the target from the deps migrator source (:deps/resolved)",
         %{tmp_dir: tmp_dir} do
      write_tenant_dep(tmp_dir, 4, "0.12.0")
      migrations_dir = Path.join(tmp_dir, "priv/repo/migrations")

      write_migration(
        migrations_dir,
        "20260806120000_upgrade_defdo_tenant_migrator_v04.exs",
        ~S|def up, do: Defdo.Tenant.Migrator.up(version: 4, prefix: "app")| <>
          "\n" <> ~S|def down, do: Defdo.Tenant.Migrator.down(version: 4, prefix: "app")|
      )

      {response, _state} = call(11, "defdo_saas.migrator_chain", %{"root" => tmp_dir})
      payload = decode_tool_payload(response)

      assert payload["target_version"] == 4
      assert payload["target_version_source"] == "deps"
      assert payload["target_version_confidence"] == "resolved"
      assert payload["resolved_dependency"] == "defdo_tenant"
      assert payload["resolved_version"] == "0.12.0"
      assert payload["status"] == %{"kind" => "current"}
      assert [wrapper] = payload["wrappers"]
      assert wrapper["up"] == 4
      assert wrapper["down"] == 4
      assert wrapper["prefix"] == "app"
      assert payload["asymmetric"] == []
    end

    @tag :tmp_dir
    test "a wrapper behind the resolved dependency is behind -- the case that broke things",
         %{tmp_dir: tmp_dir} do
      # deps ship v4, wrappers reach only v3: exactly the 0.10.x -> 0.13.0 break.
      write_tenant_dep(tmp_dir, 4, "0.13.0")
      migrations_dir = Path.join(tmp_dir, "priv/repo/migrations")

      write_migration(
        migrations_dir,
        "20260101000000_wrapper_v03.exs",
        ~S|def up, do: Defdo.Tenant.Migrator.up(version: 3, prefix: "app")| <>
          "\n" <> ~S|def down, do: Defdo.Tenant.Migrator.down(version: 3, prefix: "app")|
      )

      {response, _state} = call(12, "defdo_saas.migrator_chain", %{"root" => tmp_dir})
      payload = decode_tool_payload(response)

      assert payload["target_version"] == 4
      assert payload["target_version_source"] == "deps"
      assert payload["resolved_version"] == "0.13.0"
      assert payload["status"] == %{"kind" => "behind", "applied" => 3, "target" => 4}
    end

    @tag :tmp_dir
    test "falls back to mix.lock when deps are not fetched (:lock/from_lock)",
         %{tmp_dir: tmp_dir} do
      write_lock(tmp_dir, "defdo_tenant", "0.12.0")
      migrations_dir = Path.join(tmp_dir, "priv/repo/migrations")

      write_migration(
        migrations_dir,
        "20260806120000_upgrade_defdo_tenant_migrator_v04.exs",
        ~S|def up, do: Defdo.Tenant.Migrator.up(version: 4, prefix: "app")| <>
          "\n" <> ~S|def down, do: Defdo.Tenant.Migrator.down(version: 4, prefix: "app")|
      )

      {response, _state} = call(13, "defdo_saas.migrator_chain", %{"root" => tmp_dir})
      payload = decode_tool_payload(response)

      assert payload["target_version"] == 4
      assert payload["target_version_source"] == "lock"
      assert payload["target_version_confidence"] == "from_lock"
      assert payload["resolved_version"] == "0.12.0"
      assert payload["status"] == %{"kind" => "current"}
    end

    @tag :tmp_dir
    test "asymmetric down and prefix conflicts are both surfaced", %{tmp_dir: tmp_dir} do
      migrations_dir = Path.join(tmp_dir, "priv/repo/migrations")

      write_migration(
        migrations_dir,
        "20260101000000_install.exs",
        ~S|def up, do: Defdo.Tenant.Migrator.up(version: 4, prefix: "defdo_tenant")| <>
          "\n" <> ~S|def down, do: Defdo.Tenant.Migrator.down(version: 3, prefix: "defdo_tenant")|
      )

      {response, _state} =
        call(12, "defdo_saas.migrator_chain", %{"root" => tmp_dir, "prefix" => "my_app"})

      payload = decode_tool_payload(response)

      assert [asym] = payload["asymmetric"]
      assert asym["up"] == 4
      assert asym["down"] == 3

      assert payload["prefix_checked"] == true
      assert [conflict] = payload["prefix_conflicts"]
      assert conflict["prefix"] == "defdo_tenant"
    end

    test "defaults migrations_path to <root>/priv/repo/migrations and migrator to the known default" do
      {response, _state} = call(13, "defdo_saas.migrator_chain", %{"root" => "."})
      payload = decode_tool_payload(response)

      assert payload["migrations_path"] == Path.join([".", "priv", "repo", "migrations"])
      assert payload["migrator"] == MigratorChain.default_migrator()
    end

    test "a root that does not exist is an error, not an empty result" do
      {response, _state} =
        call(14, "defdo_saas.migrator_chain", %{"root" => "/nonexistent/defdo-saas-root"})

      assert response["error"]["code"] == -32_002
      assert response["error"]["message"] == "Project root not found"
      assert response["error"]["data"]["root"] == "/nonexistent/defdo-saas-root"
    end
  end

  describe "defdo_saas.audit" do
    @tag :tmp_dir
    test "composes findings across checks, with counts and an exit status", %{tmp_dir: tmp_dir} do
      {response, _state} = call(20, "defdo_saas.audit", %{"root" => tmp_dir, "deps" => []})
      payload = decode_tool_payload(response)

      assert payload["root"] == tmp_dir
      assert Enum.any?(payload["findings"], &(&1["check"] == "migrator_chain"))
      assert Enum.any?(payload["findings"], &(&1["check"] == "stack_deps"))
      assert payload["counts"]["error"] > 0
      assert payload["exit_status"] == 1
    end

    @tag :tmp_dir
    test "deps are read from the tool call, not discovered, and clear the stack_deps errors",
         %{tmp_dir: tmp_dir} do
      migrations_dir = Path.join(tmp_dir, "priv/repo/migrations")

      write_migration(
        migrations_dir,
        "20260806120000_upgrade_defdo_tenant_migrator_v04.exs",
        ~S|def up, do: Defdo.Tenant.Migrator.up(version: 4, prefix: "app")| <>
          "\n" <> ~S|def down, do: Defdo.Tenant.Migrator.down(version: 4, prefix: "app")|
      )

      deps = [
        %{"name" => "defdo_tenant", "requirement" => "~> 0.12", "organization" => "defdo"},
        %{"name" => "defdo_tenant_plug", "requirement" => "~> 0.2"},
        %{"name" => "defdo_tenant_boundary", "requirement" => "~> 0.2"},
        %{"name" => "defdo_vault", "requirement" => "~> 0.10"}
      ]

      {response, _state} = call(21, "defdo_saas.audit", %{"root" => tmp_dir, "deps" => deps})
      payload = decode_tool_payload(response)

      refute Enum.any?(
               payload["findings"],
               &(&1["check"] == "stack_deps" and &1["severity"] == "error")
             )
    end

    @tag :tmp_dir
    test "strict: true fails the exit status on warnings too", %{tmp_dir: tmp_dir} do
      migrations_dir = Path.join(tmp_dir, "priv/repo/migrations")

      write_migration(
        migrations_dir,
        "20260806150000_upgrade_defdo_tenant_migrator_v04.exs",
        ~S|def up, do: Defdo.Tenant.Migrator.up(version: 4, prefix: "defdo_auth")| <>
          "\n" <> ~S|def down, do: Defdo.Tenant.Migrator.down(version: 3, prefix: "defdo_auth")|
      )

      deps = [
        %{"name" => "defdo_tenant", "requirement" => "~> 0.12"},
        %{"name" => "defdo_tenant_plug", "requirement" => "~> 0.2"},
        %{"name" => "defdo_tenant_boundary", "requirement" => "~> 0.2"},
        %{"name" => "defdo_vault", "requirement" => "~> 0.10"}
      ]

      {lenient, _state} = call(22, "defdo_saas.audit", %{"root" => tmp_dir, "deps" => deps})

      {strict, _state} =
        call(23, "defdo_saas.audit", %{"root" => tmp_dir, "deps" => deps, "strict" => true})

      assert decode_tool_payload(lenient)["exit_status"] == 0
      assert decode_tool_payload(strict)["exit_status"] == 1
    end

    test "a root that does not exist is an error, not an empty finding list" do
      {response, _state} =
        call(24, "defdo_saas.audit", %{"root" => "/nonexistent/defdo-saas-root"})

      assert response["error"]["code"] == -32_002
      assert response["error"]["message"] == "Project root not found"
      assert response["error"]["data"]["root"] == "/nonexistent/defdo-saas-root"
    end

    @tag :tmp_dir
    test "a malformed dep entry is a structured error, not a crash", %{tmp_dir: tmp_dir} do
      {response, _state} =
        call(25, "defdo_saas.audit", %{"root" => tmp_dir, "deps" => [%{"no_name" => true}]})

      assert response["error"]["code"] == -32_602
      assert response["error"]["message"] == "Invalid dependency entry"
    end
  end
end

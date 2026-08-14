defmodule Defdo.Tasks.Saas.HexBaselineTest do
  use ExUnit.Case, async: true

  alias Defdo.Tasks.Saas.HexBaseline

  doctest HexBaseline

  @success_output """
  Config: {:defdo_tenant, "~> 0.13", organization: :defdo}
  Locked version: 0.13.0

  Recent releases:
    0.13.0 (2026-08-01)
    0.12.0 (2026-05-01)
    0.11.0 (2026-01-01)
    ...

  Downloads:
    All time: 1234
  """

  describe "resolve/2" do
    test "a successful lookup returns the highest published stable version" do
      fetch = fn :defdo_tenant -> {:ok, 0, @success_output} end

      assert {:ok, version} = HexBaseline.resolve(:defdo_tenant, fetch: fetch)
      assert to_string(version) == "0.13.0"
    end

    test "pre-releases never win over a published stable version" do
      output = """
      Recent releases:
        0.14.0-rc.1 (2026-08-10)
        0.13.0 (2026-08-01)

      """

      fetch = fn :pkg -> {:ok, 0, output} end

      assert {:ok, version} = HexBaseline.resolve(:pkg, fetch: fetch)
      assert to_string(version) == "0.13.0"
    end

    test "an unreachable registry degrades to :error, never a version" do
      fetch = fn :defdo_tenant -> {:error, :nxdomain} end

      assert HexBaseline.resolve(:defdo_tenant, fetch: fetch) == {:error, :nxdomain}
    end

    test "a nonzero exit (offline, expired org auth, no such package) is :error" do
      # `mix hex.info` answers a private-org package the caller cannot see
      # exactly the way it answers one that does not exist -- this resolver
      # must not guess which one it was. Both come back as {:error, _}, never
      # as a claim about the package's existence or version.
      fetch = fn :defdo_tenant ->
        {:ok, 1, "No package with name defdo_tenant\n"}
      end

      assert {:error, {:exit, 1, "No package with name defdo_tenant"}} =
               HexBaseline.resolve(:defdo_tenant, fetch: fetch)
    end

    test "output with no recognizable release list is :error, not a crash" do
      fetch = fn :pkg -> {:ok, 0, "some unexpected output\n"} end

      assert {:error, "some unexpected output"} = HexBaseline.resolve(:pkg, fetch: fetch)
    end

    test "a fetch function that raises is still contained to {:error, _}" do
      fetch = fn :pkg -> raise "boom" end

      assert {:error, "boom"} = HexBaseline.resolve(:pkg, fetch: fetch)
    end
  end

  describe "resolve_all/2" do
    test "resolves every name exactly once, mixing success and failure" do
      calls = :counters.new(1, [])

      fetch = fn
        :defdo_tenant ->
          :counters.add(calls, 1, 1)
          {:ok, 0, @success_output}

        :defdo_vault ->
          :counters.add(calls, 1, 1)
          {:error, :nxdomain}
      end

      result = HexBaseline.resolve_all([:defdo_tenant, :defdo_vault], fetch: fetch)

      assert {:ok, version} = result[:defdo_tenant]
      assert to_string(version) == "0.13.0"
      assert result[:defdo_vault] == {:error, :nxdomain}
      assert :counters.get(calls, 1) == 2
    end

    test "an empty name list resolves nothing and never calls fetch" do
      fetch = fn _name -> raise "should never be called" end

      assert HexBaseline.resolve_all([], fetch: fetch) == %{}
    end
  end
end

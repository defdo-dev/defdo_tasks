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

    test "an expired Hex session is reported as such, not as a missing package" do
      # `mix hex.info` prints the expiry notice and *then* "No package with
      # name X" -- for every private package, published or not. Reporting the
      # last line alone sends the operator hunting for a package that is
      # sitting in their own mix.lock.
      output = """
      \e[33mYour authentication session has expired and could not be refreshed. Continuing without credentials; requests for private resources will fail or prompt for authentication. Run `mix hex.user auth` to re-authenticate\e[0m
      No package with name defdo_tenant
      """

      fetch = fn :defdo_tenant -> {:ok, 1, output} end

      assert HexBaseline.resolve(:defdo_tenant, fetch: fetch) == {:error, :expired_session}
    end

    test "a genuine missing package stays distinguishable from an expired session" do
      fetch = fn :nope -> {:ok, 1, "No package with name nope\n"} end

      assert HexBaseline.resolve(:nope, fetch: fetch) ==
               {:error, {:exit, 1, "No package with name nope"}}
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

  describe "credential_env/1" do
    # `mix hex.info` authenticates with the Hex user session, not the repo key
    # `mix deps.get` uses, so a caller who can resolve every private dep still
    # gets "No package with name X" once that session lapses. Forwarding the
    # organization key the environment already carries is what lets the check
    # actually run. Every assertion here is about the *presence* and shape of
    # the credential -- the value is never asserted on, printed, or fixtured.
    test "forwards HEX_API_KEY when the environment defines it" do
      getenv = fn
        "HEX_API_KEY" -> "hex-api-key-placeholder"
        _other -> nil
      end

      assert [{"HEX_API_KEY", value}] = HexBaseline.credential_env(getenv)
      assert byte_size(value) > 0
    end

    test "falls back to HEX_ORG_TOKEN, forwarded under the name Hex reads" do
      getenv = fn
        "HEX_ORG_TOKEN" -> "hex-org-token-placeholder"
        _other -> nil
      end

      assert [{"HEX_API_KEY", value}] = HexBaseline.credential_env(getenv)
      assert byte_size(value) > 0
    end

    test "an absent or blank credential forwards nothing, leaving Hex's own session in charge" do
      assert HexBaseline.credential_env(fn _ -> nil end) == []
      assert HexBaseline.credential_env(fn _ -> "   " end) == []
    end

    test "the real fetch passes the credential through to mix hex.info" do
      test_pid = self()

      cmd = fn "mix", args, opts ->
        send(test_pid, {:cmd, args, opts})
        {"Recent releases:\n  1.0.0 (2026-01-01)\n\n", 0}
      end

      getenv = fn
        "HEX_ORG_TOKEN" -> "hex-org-token-placeholder"
        _other -> nil
      end

      assert {:ok, _version} = HexBaseline.resolve(:defdo_tenant, cmd: cmd, getenv: getenv)

      assert_receive {:cmd, args, opts}
      assert "hex.info" in args
      assert ["defdo"] = Enum.take(args, -1)

      env = Keyword.fetch!(opts, :env)
      assert [{"HEX_API_KEY", value}] = env
      assert byte_size(value) > 0
    end

    test "with no credential in the environment the fetch passes an empty env" do
      test_pid = self()

      cmd = fn "mix", _args, opts ->
        send(test_pid, {:cmd, opts})
        {"Recent releases:\n  1.0.0 (2026-01-01)\n\n", 0}
      end

      assert {:ok, _version} =
               HexBaseline.resolve(:defdo_tenant, cmd: cmd, getenv: fn _ -> nil end)

      assert_receive {:cmd, opts}
      assert Keyword.fetch!(opts, :env) == []
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

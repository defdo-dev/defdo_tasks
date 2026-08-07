defmodule Defdo.Tasks.Saas.StackTest do
  use ExUnit.Case, async: true

  alias Defdo.Tasks.Saas.Stack

  doctest Stack

  describe "select/1" do
    test "the core tier is what makes an app a defdo SaaS app" do
      names = Stack.select([:core]) |> Enum.map(& &1.name)

      assert names == [:defdo_tenant, :defdo_tenant_plug, :defdo_tenant_boundary, :defdo_vault]
    end

    test "defdo_payments is recommended, not core" do
      assert Stack.fetch(:defdo_payments).tier == :recommended
      refute :defdo_payments in Enum.map(Stack.select([:core]), & &1.name)
    end

    test "an unpublished package never appears in a default selection" do
      # defdo_tenant_provision exists in the estate but has never resolved from
      # Hex. Emitting it by default would generate a mix.exs that cannot
      # `deps.get`.
      refute Stack.fetch(:defdo_tenant_provision).published?
      refute :defdo_tenant_provision in Enum.map(Stack.select([:core, :recommended]), & &1.name)
    end

    test "asking for the optional tier by name does surface it" do
      assert :defdo_tenant_provision in Enum.map(Stack.select([:optional]), & &1.name)
    end
  end

  describe "to_tuple/1 and to_source/1" do
    test "every hex package carries the private organization" do
      for dep <- Stack.all(), dep.hex do
        assert {_name, _req, [organization: :defdo]} = Stack.to_tuple(dep)
        assert Stack.to_source(dep) =~ "organization: :defdo"
      end
    end

    test "the rendered source parses as the dep tuple it claims to be" do
      for dep <- Stack.all() do
        assert {:ok, ast} = Code.string_to_quoted(Stack.to_source(dep))
        assert {:{}, _, _} = ast
      end
    end
  end

  describe "check_requirement/2" do
    test "a two-part requirement admits later minors, which is the point" do
      # `~> 0.10` means `>= 0.10.0 and < 1.0.0`. Every app in this estate that
      # declares it can already resolve defdo_tenant 0.12 -- which is why so
      # many of them are exposed to the v4 gap rather than protected from it.
      assert Stack.check_requirement(:defdo_tenant, "~> 0.10") == :ok
      assert Stack.check_requirement(:defdo_tenant, "~> 0.11") == :ok
      assert Stack.check_requirement(:defdo_tenant, "~> 0.12") == :ok
    end

    test "a three-part requirement is a freeze, and is reported as stale" do
      # defdo_shop declares `~> 0.8.4`, which cannot admit 0.9.0 at all.
      assert Stack.check_requirement(:defdo_tenant, "~> 0.8.4") == {:stale, "~> 0.12"}
    end

    test "an or-requirement is satisfied if either branch admits the floor" do
      assert Stack.check_requirement(:defdo_tenant, "~> 0.10.2 or ~> 0.11") == :ok
    end

    test "packages outside the stack are not this module's business" do
      assert Stack.check_requirement(:phoenix, "~> 1.0.0") == :ok
    end

    test "an unparseable requirement is reported, not swallowed" do
      assert {:invalid, "not a version"} =
               Stack.check_requirement(:defdo_tenant, "not a version")
    end
  end
end

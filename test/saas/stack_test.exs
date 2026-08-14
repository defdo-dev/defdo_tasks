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

  describe "compare_to_baseline/2" do
    test "a two-part requirement admits later minors, which is the point" do
      # `~> 0.12` means `>= 0.12.0 and < 1.0.0`. An app declaring this can
      # already admit whatever 0.x Hex currently ships.
      assert Stack.compare_to_baseline("~> 0.12", "0.13.0") == :ok
      assert Stack.compare_to_baseline("~> 0.10", "0.13.0") == :ok
    end

    test "a three-part requirement that has been outpaced is reported as behind" do
      # A patch-level pin like `~> 0.13.0` cannot admit `0.15.0` at all --
      # this is the freeze that quietly held defdo_shop back.
      assert Stack.compare_to_baseline("~> 0.13.0", "0.15.0") == {:behind, "0.15.0"}
    end

    test "a requirement newer than the current release is ahead, not behind" do
      # This is the direction the old hardcoded-baseline comparison got
      # backwards: an app declaring `~> 0.13` while Hex has only published up
      # to `0.12.x` is not "pinned behind the stack" -- if anything the
      # baseline is behind the app.
      assert Stack.compare_to_baseline("~> 0.13", "0.12.0") == {:ahead, "0.13.0"}
    end

    test "an or-requirement is satisfied if either branch admits the release" do
      assert Stack.compare_to_baseline("~> 0.10.2 or ~> 0.11", "0.11.5") == :ok
    end

    test "an unparseable requirement is reported, not swallowed" do
      assert Stack.compare_to_baseline("not a version", "0.13.0") == {:invalid, "not a version"}
    end

    test "accepts the current release as either a string or a parsed Version" do
      assert Stack.compare_to_baseline("~> 0.12", Version.parse!("0.13.0")) == :ok
    end
  end
end

defmodule Mix.Tasks.Defdo.Saas.InstallTest do
  @moduledoc """
  `defdo_tenant` is not a dependency of this package, so these exercise the
  first pass: the dependency set, which is the part that must be right before
  anything can be fetched. The second pass is verified end to end against a real
  project (see README, "Verifying the generator").
  """
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Defdo.Tasks.Saas.Stack

  defp mix_exs(igniter) do
    igniter.rewrite
    |> Rewrite.source!("mix.exs")
    |> Rewrite.Source.get(:content)
  end

  test "adds the core stack with the private organization" do
    source = test_project() |> Igniter.compose_task("defdo.saas.install", []) |> mix_exs()

    for dep <- Stack.select([:core]) do
      assert source =~ ~s({:#{dep.name}, "#{dep.requirement}", organization: :defdo}),
             "missing #{dep.name}"
    end
  end

  test "adds defdo_payments by default, because tenants are usually billed" do
    source = test_project() |> Igniter.compose_task("defdo.saas.install", []) |> mix_exs()

    assert source =~ ~s({:defdo_payments, "~> 0.3", organization: :defdo})
  end

  test "--no-with-payments leaves it out" do
    source =
      test_project()
      |> Igniter.compose_task("defdo.saas.install", ["--no-with-payments"])
      |> mix_exs()

    refute source =~ "defdo_payments"
  end

  test "never adds the unpublished provisioning package unless asked" do
    source = test_project() |> Igniter.compose_task("defdo.saas.install", []) |> mix_exs()

    refute source =~ "defdo_tenant_provision"
  end

  test "--with-provision opts in" do
    source =
      test_project()
      |> Igniter.compose_task("defdo.saas.install", ["--with-provision"])
      |> mix_exs()

    assert source =~ ~s({:defdo_tenant_provision, "~> 0.1", organization: :defdo})
  end

  test "the mix.exs it produces still parses" do
    source = test_project() |> Igniter.compose_task("defdo.saas.install", []) |> mix_exs()

    assert {:ok, _ast} = Code.string_to_quoted(source)
  end

  test "re-running does not duplicate or rewrite a dependency" do
    igniter = test_project() |> Igniter.compose_task("defdo.saas.install", [])
    once = mix_exs(igniter)

    twice = igniter |> Igniter.compose_task("defdo.saas.install", []) |> mix_exs()

    assert once == twice
  end

  test "does not overwrite a requirement the app widened on purpose" do
    igniter =
      test_project()
      |> Igniter.Project.Deps.add_dep({:defdo_tenant, "~> 0.11 or ~> 0.12"})
      |> Igniter.compose_task("defdo.saas.install", [])

    assert mix_exs(igniter) =~ ~s({:defdo_tenant, "~> 0.11 or ~> 0.12"})
  end

  test "explains that a second pass is needed and why" do
    igniter = test_project() |> Igniter.compose_task("defdo.saas.install", [])

    assert Enum.any?(igniter.notices, &(&1 =~ "pass one of two"))
    assert Enum.any?(igniter.notices, &(&1 =~ "mix deps.get"))
  end

  test "rejects an enforcement mode that does not exist" do
    assert_raise Mix.Error, ~r/unknown --enforcement/, fn ->
      test_project() |> Igniter.compose_task("defdo.saas.install", ["--enforcement", "yolo"])
    end
  end
end

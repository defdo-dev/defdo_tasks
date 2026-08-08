defmodule Defdo.Tasks.Saas.StatusTest do
  use ExUnit.Case, async: true

  alias Defdo.Tasks.Saas.Status

  doctest Status

  # A lock line for a hex package, with optional transitive requirements, close
  # enough to a real mix.lock entry that the parsers are exercised on the real
  # shape rather than one invented for the test.
  defp lock_line(name, version, transitive \\ []) do
    inner =
      Enum.map_join(transitive, ", ", fn {dep, req} ->
        ~s|{:#{dep}, "#{req}", [hex: :#{dep}, repo: "hexpm:defdo"]}|
      end)

    ~s|  "#{name}": {:hex, :#{name}, "#{version}", "hash", [:mix], [#{inner}], "hexpm:defdo", "hash2"},|
  end

  defp mkrepo(root, name, opts) do
    path = Path.join(root, name)
    File.mkdir_p!(Path.join(path, "priv/repo/migrations"))
    # A plain file marker is enough for git_repo?/1, which only checks existence.
    File.write!(Path.join(path, ".git"), "gitdir: fake")

    if lock = opts[:lock], do: File.write!(Path.join(path, "mix.lock"), lock)

    for {file, source} <- opts[:migrations] || [] do
      File.write!(Path.join([path, "priv/repo/migrations", file]), source)
    end

    path
  end

  # A runner that answers from a per-test table keyed on {cmd, first_arg_or_verb}.
  # Anything unmatched degrades to a nonzero exit, which is the honest default for
  # a command whose answer this test did not stub.
  defp runner(table) do
    fn cmd, args, _cd ->
      key = runner_key(cmd, args)
      Map.get(table, key, {1, ""})
    end
  end

  defp runner_key("gh", _args), do: :gh
  defp runner_key("git", ["-C", _path, "rev-parse" | _]), do: :branch
  defp runner_key("git", ["-C", _path, "status" | _]), do: :status
  defp runner_key("git", ["-C", _path, "fetch" | _]), do: :fetch
  defp runner_key("git", ["-C", _path, "rev-list" | _]), do: :rev_list
  defp runner_key("git", ["-C", _path, "show" | _]), do: :show
  defp runner_key(_cmd, _args), do: :other

  @v4_wrapper ~S|def up, do: Defdo.Tenant.Migrator.up(version: 4, prefix: "app")| <>
                "\n" <> ~S|def down, do: Defdo.Tenant.Migrator.down(version: 4, prefix: "app")|

  @v3_wrapper ~S|def up, do: Defdo.Tenant.Migrator.up(version: 3, prefix: "app")| <>
                "\n" <> ~S|def down, do: Defdo.Tenant.Migrator.down(version: 3, prefix: "app")|

  describe "open PRs" do
    @tag :tmp_dir
    test "decodes gh output into structured PRs", %{tmp_dir: tmp_dir} do
      mkrepo(tmp_dir, "app_a", lock: lock_line("defdo_tenant", "0.13.0"))

      gh_json =
        Jason.encode!([
          %{
            "number" => 12,
            "title" => "Adopt defdo_tenant 0.13",
            "headRefName" => "feat/adopt",
            "baseRefName" => "main",
            "isDraft" => false,
            "files" => [%{"path" => "mix.lock"}, %{"path" => "mix.exs"}]
          }
        ])

      report =
        Status.report(tmp_dir,
          runner: runner(%{gh: {0, gh_json}}),
          fetch: false,
          latest: "0.13.0"
        )

      [repo] = report.repos
      assert repo.pull_requests.available == true
      assert [pr] = repo.pull_requests.items
      assert pr.number == 12
      assert pr.branch == "feat/adopt"
      assert pr.base == "main"
      assert pr.files_changed == 2
      assert report.gh_available == true
    end

    @tag :tmp_dir
    test "gh missing degrades to unavailable, never zero", %{tmp_dir: tmp_dir} do
      mkrepo(tmp_dir, "app_a", lock: lock_line("defdo_tenant", "0.13.0"))

      report = Status.report(tmp_dir, runner: runner(%{gh: {:enoent, ""}}), fetch: false)

      [repo] = report.repos
      assert repo.pull_requests.available == false
      assert repo.pull_requests.reason =~ "not installed"
      assert repo.pull_requests.items == []
      assert report.gh_available == false
    end

    @tag :tmp_dir
    test "gh unauthenticated says so rather than reporting zero PRs", %{tmp_dir: tmp_dir} do
      mkrepo(tmp_dir, "app_a", lock: lock_line("defdo_tenant", "0.13.0"))

      table = %{gh: {1, "gh auth login required to query PRs"}}
      report = Status.report(tmp_dir, runner: runner(table), fetch: false)

      [repo] = report.repos
      assert repo.pull_requests.available == false
      assert repo.pull_requests.reason =~ "authenticated"
    end
  end

  describe "dependency drift" do
    @tag :tmp_dir
    test "a three-segment requirement that refuses the latest is requirement_blocks",
         %{tmp_dir: tmp_dir} do
      lock =
        lock_line("defdo_tenant", "0.10.5") <>
          "\n" <> lock_line("defdo_cms", "0.8.24", [{"defdo_tenant", "~> 0.10.2"}])

      mkrepo(tmp_dir, "notification_hub", lock: lock)

      report = Status.report(tmp_dir, runner: runner(%{}), fetch: false, latest: "0.13.0")

      [repo] = report.repos
      assert repo.drift.pinned == "0.10.5"
      assert repo.drift.latest == "0.13.0"
      assert repo.drift.requirement == "~> 0.10.2"
      assert repo.drift.cap == :minor
      assert repo.drift.admits_latest == false
      assert repo.drift.verdict == :requirement_blocks
    end

    @tag :tmp_dir
    test "omitting latest leaves the pinned-vs-latest comparison unknown, not guessed",
         %{tmp_dir: tmp_dir} do
      mkrepo(tmp_dir, "app_a", lock: lock_line("defdo_tenant", "0.10.5"))

      report = Status.report(tmp_dir, runner: runner(%{}), fetch: false)

      [repo] = report.repos
      assert repo.drift.latest == nil
      assert repo.drift.verdict == :unknown
    end
  end

  describe "migrator chain" do
    @tag :tmp_dir
    test "counts a version that arrives indirectly through defdo_vault",
         %{tmp_dir: tmp_dir} do
      # No wrapper file, but defdo_vault is locked, so the app is at v3, not v0.
      lock =
        lock_line("defdo_tenant", "0.13.0") <> "\n" <> lock_line("defdo_vault", "0.10.0")

      mkrepo(tmp_dir, "core_graph", lock: lock)

      report = Status.report(tmp_dir, runner: runner(%{}), fetch: false, latest: "0.13.0")

      [repo] = report.repos
      assert repo.migrator.direct_applied == 0
      assert repo.migrator.indirect_floor == 3
      assert repo.migrator.effective_applied == 3
      assert repo.migrator.target == 4
      assert repo.migrator.target_source == "lock"
      assert repo.migrator.status == "behind"
    end

    @tag :tmp_dir
    test "a direct v4 wrapper reads as current", %{tmp_dir: tmp_dir} do
      mkrepo(tmp_dir, "status_app",
        lock: lock_line("defdo_tenant", "0.13.0"),
        migrations: [{"20260806120000_wrapper.exs", @v4_wrapper}]
      )

      report = Status.report(tmp_dir, runner: runner(%{}), fetch: false, latest: "0.13.0")

      [repo] = report.repos
      assert repo.migrator.direct_applied == 4
      assert repo.migrator.effective_applied == 4
      assert repo.migrator.status == "current"
    end

    @tag :tmp_dir
    test "a wrapper behind the locked target reads as behind", %{tmp_dir: tmp_dir} do
      mkrepo(tmp_dir, "order",
        lock: lock_line("defdo_tenant", "0.13.0"),
        migrations: [{"20260101000000_wrapper.exs", @v3_wrapper}]
      )

      report = Status.report(tmp_dir, runner: runner(%{}), fetch: false, latest: "0.13.0")

      [repo] = report.repos
      assert repo.migrator.effective_applied == 3
      assert repo.migrator.target == 4
      assert repo.migrator.status == "behind"
    end
  end

  describe "blocked-by" do
    @tag :tmp_dir
    test "names the published dependency whose requirement holds the estate back",
         %{tmp_dir: tmp_dir} do
      lock =
        lock_line("defdo_tenant", "0.10.5") <>
          "\n" <> lock_line("defdo_cms", "0.8.24", [{"defdo_tenant", "~> 0.10.2"}])

      mkrepo(tmp_dir, "notification_hub", lock: lock)

      report = Status.report(tmp_dir, runner: runner(%{}), fetch: false, latest: "0.13.0")

      [repo] = report.repos
      assert repo.blocked_by.available == true
      assert [blocker] = repo.blocked_by.items
      assert blocker.package == "defdo_cms"
      assert blocker.version == "0.8.24"
      assert blocker.requirement == "~> 0.10.2"

      assert Enum.any?(report.summary, &(&1 =~ "BLOCKED" and &1 =~ "defdo_cms"))
    end

    @tag :tmp_dir
    test "without a latest to compare against, blocked-by is unknown not empty",
         %{tmp_dir: tmp_dir} do
      lock =
        lock_line("defdo_tenant", "0.10.5") <>
          "\n" <> lock_line("defdo_cms", "0.8.24", [{"defdo_tenant", "~> 0.10.2"}])

      mkrepo(tmp_dir, "notification_hub", lock: lock)

      report = Status.report(tmp_dir, runner: runner(%{}), fetch: false)

      [repo] = report.repos
      assert repo.blocked_by.available == false
      assert repo.blocked_by.reason =~ "latest"
    end
  end

  describe "local vs origin divergence" do
    @tag :tmp_dir
    test "flags a local checkout whose lock disagrees with origin", %{tmp_dir: tmp_dir} do
      # Local pins 0.12.0; origin's mix.lock pins 0.10.5 -- a real "the newer
      # version lives on an unmerged branch" divergence.
      mkrepo(tmp_dir, "cms", lock: lock_line("defdo_tenant", "0.12.0"))

      table = %{
        branch: {0, "main\n"},
        status: {0, ""},
        rev_list: {0, "0\t3\n"},
        show: {0, lock_line("defdo_tenant", "0.10.5")}
      }

      report = Status.report(tmp_dir, runner: runner(table), fetch: true, latest: "0.13.0")

      [repo] = report.repos
      assert repo.git.branch == "main"
      assert repo.git.dirty == false
      assert repo.git.has_origin == true
      assert repo.git.ahead == 3
      assert repo.git.behind == 0
      assert repo.git.local_pin == "0.12.0"
      assert repo.git.origin_pin == "0.10.5"
      assert repo.git.diverges_from_origin == true
      assert repo.git.answered_from == "origin"

      assert Enum.any?(report.summary, &(&1 =~ "DIVERGED" and &1 =~ "cms"))
    end

    @tag :tmp_dir
    test "a repo with no reachable origin says so instead of inventing an answer",
         %{tmp_dir: tmp_dir} do
      mkrepo(tmp_dir, "skeleton", lock: lock_line("defdo_tenant", "0.13.0"))

      table = %{branch: {0, "main\n"}, status: {0, ""}}
      report = Status.report(tmp_dir, runner: runner(table), fetch: true, latest: "0.13.0")

      [repo] = report.repos
      assert repo.git.has_origin == false
      assert repo.git.ahead == nil
      assert repo.git.origin_pin == nil
      assert repo.git.answered_from =~ "local checkout"
    end
  end

  describe "discovery and aggregation" do
    @tag :tmp_dir
    test "discovers only git repos under the root and orders a what's-next summary",
         %{tmp_dir: tmp_dir} do
      mkrepo(tmp_dir, "current_app",
        lock: lock_line("defdo_tenant", "0.13.0"),
        migrations: [{"20260806120000_wrapper.exs", @v4_wrapper}]
      )

      mkrepo(tmp_dir, "behind_app",
        lock: lock_line("defdo_tenant", "0.13.0"),
        migrations: [{"20260101000000_wrapper.exs", @v3_wrapper}]
      )

      # A non-repo directory that must be ignored.
      File.mkdir_p!(Path.join(tmp_dir, "not_a_repo"))

      report = Status.report(tmp_dir, runner: runner(%{}), fetch: false, latest: "0.13.0")

      names = Enum.map(report.repos, & &1.repo)
      assert names == ["behind_app", "current_app"]
      assert Enum.any?(report.summary, &(&1 =~ "MIGRATOR" and &1 =~ "behind_app"))
      assert List.last(report.summary) =~ "2 repo(s) under review"
    end

    @tag :tmp_dir
    test "an explicit repos list narrows discovery", %{tmp_dir: tmp_dir} do
      mkrepo(tmp_dir, "app_a", lock: lock_line("defdo_tenant", "0.13.0"))
      mkrepo(tmp_dir, "app_b", lock: lock_line("defdo_tenant", "0.13.0"))

      report =
        Status.report(tmp_dir, runner: runner(%{}), fetch: false, repos: ["app_b"])

      assert Enum.map(report.repos, & &1.repo) == ["app_b"]
    end
  end
end

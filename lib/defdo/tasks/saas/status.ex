defmodule Defdo.Tasks.Saas.Status do
  @moduledoc """
  Answers "where are we" across the estate by reading live state, not memory.

  On 2026-08-07 a `defdo_tenant` 0.10.x -> 0.13.0 adoption touched ~15 repos, and
  reconstructing where each one stood took a whole session of the same commands
  by hand: `gh pr list` per repo, `git show origin/main:mix.lock | grep`,
  `git ls-tree` for wrapper files. Nothing composed them into an answer. This
  module is that composition, and only that: it reads, it never writes.

  ## What it reads, and why each is a trap on its own

    * **Open PRs** — via `gh`. When `gh` is missing or unauthenticated the answer
      is *unknown*, never zero: a confident "no open PRs" from a tool that could
      not ask is worse than silence.
    * **Dependency drift** — a repo's `mix.lock` pin against a caller-supplied
      latest, plus whether the *requirement* admits an upgrade at all. A
      three-segment `~> 0.10.2` caps at `< 0.11.0` and will never move on
      `mix deps.update`; a two-segment `~> 0.10` caps at `< 1.0.0` and will. That
      distinction is the difference between "run a command" and "edit a
      requirement", so it is reported explicitly (see `requirement_cap/1`).
    * **Migrator chain** — reuses `Defdo.Tasks.Saas.MigratorChain`, but counts
      the versions that arrive *indirectly*: `defdo_vault` chains tenant v1..v3
      from its own version modules, so an app with no wrapper file can still be
      at v3. Counting only direct wrappers understated `core_graph` as v2 when it
      was v3 (see `indirect_floor/1`).
    * **Blocked-by** — when a *published* dependency pins an older requirement, an
      app cannot adopt the newer version until that dependency ships. `defdo_cms`
      0.8.24 pinning `defdo_tenant ~> 0.10.2` is why `defdo_notification_hub` was
      unadoptable. This is the single most expensive thing to work out by hand
      (see `blockers/3`).
    * **Local-vs-origin divergence** — the reason requirement 5 of issue #8 is not
      optional. A stale checkout produced three wrong conclusions in one session,
      so this **fetches before reporting on origin**, states whether each answer
      came from the local checkout or `origin`, and flags when they disagree.

  ## Read-only, and injectable

  Every external call goes through a `t:runner/0` so tests drive it without a
  network, a GitHub token or a real git tree. The default runner shells out with
  `System.cmd/3` and degrades to `:enoent` when the binary is absent rather than
  raising.
  """

  alias Defdo.Tasks.Saas.MigratorChain

  @typedoc """
  Runs an external command in `cd`, returning the exit status (or `:enoent` when
  the binary is missing) and the combined output.
  """
  @type runner ::
          (cmd :: String.t(), args :: [String.t()], cd :: String.t() ->
             {non_neg_integer() | :enoent, String.t()})

  @default_package :defdo_tenant

  # `defdo_vault` chains `Defdo.Tenant.Migrator` v1..v3 from its own version
  # modules, so an app that runs the vault migrations reaches v3 without a
  # wrapper file of its own. Nothing chains v4 -- that is the whole point of the
  # wrapper this estate keeps forgetting.
  @vault_indirect_floor 3

  # ---------------------------------------------------------------------------
  # Pure analysis (doctested)
  # ---------------------------------------------------------------------------

  @doc """
  Classifies a version requirement by where its `~>` cap sits.

    * `:minor` — a three-segment `~>` (e.g. `~> 0.10.2`), capped at the next
      minor (`< 0.11.0`). It will **not** move on `mix deps.update`; adopting a
      newer minor means editing the requirement.
    * `:major` — a two-segment `~>` (e.g. `~> 0.10`), capped at the next major
      (`< 1.0.0`). `mix deps.update` can move it.
    * `:other` — anything not written as `~>` (a bare `>=`, an `or`, a pin).

      iex> Defdo.Tasks.Saas.Status.requirement_cap("~> 0.10.2")
      :minor

      iex> Defdo.Tasks.Saas.Status.requirement_cap("~> 0.10")
      :major

      iex> Defdo.Tasks.Saas.Status.requirement_cap(">= 0.0.0")
      :other
  """
  @spec requirement_cap(String.t()) :: :minor | :major | :other
  def requirement_cap(requirement) when is_binary(requirement) do
    case Regex.run(~r/^\s*~>\s*(\d+(?:\.\d+)*)/, requirement) do
      [_all, version] -> cap_for_segments(version)
      nil -> :other
    end
  end

  defp cap_for_segments(version) do
    case version |> String.split(".") |> length() do
      n when n >= 3 -> :minor
      2 -> :major
      _one -> :other
    end
  end

  @doc """
  Does `requirement` admit `candidate`? `:unknown` when either cannot be parsed.

  This is the two-segment-vs-three-segment distinction made concrete: the same
  candidate is admitted by `~> 0.10` and refused by `~> 0.10.2`.

      iex> Defdo.Tasks.Saas.Status.requirement_admits?("~> 0.10", "0.13.0")
      true

      iex> Defdo.Tasks.Saas.Status.requirement_admits?("~> 0.10.2", "0.13.0")
      false

      iex> Defdo.Tasks.Saas.Status.requirement_admits?("~> 0.10.2", "0.10.9")
      true
  """
  @spec requirement_admits?(String.t(), String.t()) :: boolean() | :unknown
  def requirement_admits?(requirement, candidate)
      when is_binary(requirement) and is_binary(candidate) do
    with {:ok, parsed_req} <- Version.parse_requirement(requirement),
         {:ok, parsed_version} <- Version.parse(candidate) do
      Version.match?(parsed_version, parsed_req)
    else
      _unparseable -> :unknown
    end
  end

  @doc """
  Summarises dependency drift for one repo: what it pins, what the latest is, and
  whether the requirement admits the latest at all.

  `:verdict` is the ordered answer a caller acts on:

    * `:current` — the pin already is the latest
    * `:upgrade_available` — the requirement admits the latest; run `deps.update`
    * `:requirement_blocks` — the latest exists but the requirement caps below it;
      the requirement must be edited, not just updated
    * `:unknown` — no latest to compare against, or an unparseable version

      iex> Defdo.Tasks.Saas.Status.drift("0.10.5", "0.13.0", "~> 0.10.2").verdict
      :requirement_blocks

      iex> Defdo.Tasks.Saas.Status.drift("0.10.5", "0.13.0", "~> 0.10").verdict
      :upgrade_available

      iex> Defdo.Tasks.Saas.Status.drift("0.13.0", "0.13.0", "~> 0.10").verdict
      :current
  """
  @spec drift(String.t() | nil, String.t() | nil, String.t() | nil) :: %{
          pinned: String.t() | nil,
          latest: String.t() | nil,
          requirement: String.t() | nil,
          cap: :minor | :major | :other | nil,
          admits_latest: boolean() | :unknown | nil,
          verdict: :current | :upgrade_available | :requirement_blocks | :unknown,
          remedy: String.t() | nil
        }
  def drift(pinned, latest, requirement) do
    cap = if is_binary(requirement), do: requirement_cap(requirement), else: nil
    admits = admits_latest(requirement, latest)
    verdict = drift_verdict(pinned, latest, admits)

    %{
      pinned: pinned,
      latest: latest,
      requirement: requirement,
      cap: cap,
      admits_latest: admits,
      verdict: verdict,
      remedy: drift_remedy(verdict)
    }
  end

  defp admits_latest(requirement, latest)
       when is_binary(requirement) and is_binary(latest),
       do: requirement_admits?(requirement, latest)

  defp admits_latest(_requirement, _latest), do: nil

  defp drift_verdict(_pinned, nil, _admits), do: :unknown
  defp drift_verdict(pinned, latest, _admits) when pinned == latest, do: :current
  defp drift_verdict(_pinned, _latest, true), do: :upgrade_available
  defp drift_verdict(_pinned, _latest, false), do: :requirement_blocks
  defp drift_verdict(_pinned, _latest, _unknown), do: :unknown

  defp drift_remedy(:upgrade_available), do: "mix deps.update <package>"
  defp drift_remedy(:requirement_blocks), do: "widen the requirement, then mix deps.update"
  defp drift_remedy(_other), do: nil

  @doc """
  The highest migrator version an app reaches *indirectly*, from its lock alone.

  `defdo_vault` chains tenant v1..v3, so a repo that locks it is at v#{@vault_indirect_floor}
  even with no wrapper file. A repo without it gets nothing indirectly.

      iex> lock = ~s|  "defdo_vault": {:hex, :defdo_vault, "0.10.0", "h", [:mix], [], "r"},|
      iex> Defdo.Tasks.Saas.Status.indirect_floor(lock)
      3

      iex> Defdo.Tasks.Saas.Status.indirect_floor("%{}")
      0
  """
  @spec indirect_floor(String.t()) :: non_neg_integer()
  def indirect_floor(lock) when is_binary(lock) do
    if MigratorChain.locked_version_from_source(lock, :defdo_vault),
      do: @vault_indirect_floor,
      else: 0
  end

  @doc """
  Repos in `lock` that pin `package` with a requirement refusing `candidate`.

  These are the blockers: a published dependency whose own requirement holds the
  estate back until it ships a release. Reads the transitive requirement each
  locked entry records for `package`.

      iex> lock = ~s|  "defdo_cms": {:hex, :defdo_cms, "0.8.24", "h", [:mix], [{:defdo_tenant, "~> 0.10.2", [hex: :defdo_tenant]}], "r"},|
      iex> Defdo.Tasks.Saas.Status.blockers(lock, :defdo_tenant, "0.13.0")
      [%{package: "defdo_cms", version: "0.8.24", requirement: "~> 0.10.2"}]

      iex> lock = ~s|  "defdo_cms": {:hex, :defdo_cms, "0.9.0", "h", [:mix], [{:defdo_tenant, "~> 0.13", [hex: :defdo_tenant]}], "r"},|
      iex> Defdo.Tasks.Saas.Status.blockers(lock, :defdo_tenant, "0.13.0")
      []
  """
  @spec blockers(String.t(), atom(), String.t()) :: [
          %{package: String.t(), version: String.t(), requirement: String.t()}
        ]
  def blockers(lock, package, candidate) when is_binary(lock) and is_atom(package) do
    package_name = to_string(package)
    name = Regex.escape(package_name)

    lock
    |> String.split("\n")
    |> Enum.flat_map(&blocker_from_line(&1, name, package_name, candidate))
  end

  defp blocker_from_line(line, name, package_name, candidate) do
    with {entry, version} when entry != package_name <- lock_entry(line),
         requirement when is_binary(requirement) <- transitive_requirement(line, name),
         false <- requirement_admits?(requirement, candidate) == true do
      [%{package: entry, version: version, requirement: requirement}]
    else
      _no_blocker -> []
    end
  end

  defp lock_entry(line) do
    case Regex.run(~r/^\s*"([^"]+)":\s*\{:hex,\s*:[^,]+,\s*"([^"]+)"/, line) do
      [_all, entry, version] -> {entry, version}
      nil -> :no_entry
    end
  end

  defp transitive_requirement(line, name) do
    case Regex.run(~r/\{:#{name},\s*"([^"]+)"/, line) do
      [_all, requirement] -> requirement
      nil -> nil
    end
  end

  @doc """
  Parses `git rev-list --left-right --count <upstream>...HEAD` output into
  `{behind, ahead}`. `git` prints behind first, then ahead, tab-separated.

      iex> Defdo.Tasks.Saas.Status.parse_ahead_behind("2\\t5\\n")
      {2, 5}

      iex> Defdo.Tasks.Saas.Status.parse_ahead_behind("garbage")
      nil
  """
  @spec parse_ahead_behind(String.t()) :: {non_neg_integer(), non_neg_integer()} | nil
  def parse_ahead_behind(output) when is_binary(output) do
    case output |> String.trim() |> String.split(~r/\s+/) do
      [behind, ahead] ->
        with {b, ""} <- Integer.parse(behind), {a, ""} <- Integer.parse(ahead) do
          {b, a}
        else
          _nonnumeric -> nil
        end

      _shape ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Composition (IO, through an injectable runner)
  # ---------------------------------------------------------------------------

  @doc """
  Builds the estate report rooted at `root`.

  Options:

    * `:package` — the dependency to check drift and blocked-by for (default
      `#{inspect(@default_package)}`)
    * `:latest` — the latest published version of `:package`, caller-supplied.
      Omit and drift is reported against the requirement's cap only, with the
      pinned-vs-latest comparison left `:unknown` rather than guessed.
    * `:fetch` — `git fetch` each repo before reading `origin` (default `true`).
      Fetch is read-only; it updates remote-tracking refs, not the working tree.
    * `:repos` — an explicit list of repo directory names under `root`, instead
      of discovering every git repo there
    * `:runner` — a `t:runner/0`, for tests
  """
  @spec report(String.t(), keyword()) :: map()
  def report(root, opts \\ []) when is_binary(root) do
    package = Keyword.get(opts, :package, @default_package)
    latest = Keyword.get(opts, :latest)
    runner = Keyword.get(opts, :runner, &system_runner/3)
    fetch? = Keyword.get(opts, :fetch, true)

    repos = discover_repos(root, opts)

    reports =
      Enum.map(repos, fn {name, path} ->
        report_repo(name, path, package, latest, fetch?, runner)
      end)

    %{
      root: root,
      package: to_string(package),
      latest: latest,
      repos: reports,
      gh_available: Enum.any?(reports, &(&1.pull_requests.available == true)),
      summary: summarize(reports, package, latest)
    }
  end

  defp discover_repos(root, opts) do
    case Keyword.get(opts, :repos) do
      names when is_list(names) -> repos_in(root, names)
      nil -> repos_in(root, list_dir(root))
    end
  end

  defp list_dir(root) do
    case File.ls(root) do
      {:ok, entries} -> Enum.sort(entries)
      {:error, _reason} -> []
    end
  end

  defp repos_in(root, names) do
    names
    |> Enum.map(&{&1, Path.join(root, &1)})
    |> Enum.filter(fn {_name, path} -> git_repo?(path) end)
  end

  defp git_repo?(path), do: File.exists?(Path.join(path, ".git"))

  defp report_repo(name, path, package, latest, fetch?, runner) do
    git = git_status(path, package, latest, fetch?, runner)
    lock = read_lock(path)

    %{
      repo: name,
      path: path,
      git: git,
      pull_requests: pull_requests(path, runner),
      drift: repo_drift(lock, package, latest),
      migrator: migrator(path, lock),
      blocked_by: blocked_by(lock, package, latest)
    }
  end

  defp read_lock(path) do
    case File.read(Path.join(path, "mix.lock")) do
      {:ok, contents} -> contents
      {:error, _reason} -> nil
    end
  end

  # -- Open PRs ---------------------------------------------------------------

  defp pull_requests(path, runner) do
    args =
      ~w(pr list --json number,title,headRefName,baseRefName,isDraft,files --limit 50)

    case runner.("gh", args, path) do
      {0, output} -> decode_pull_requests(output)
      {:enoent, _output} -> unavailable("gh is not installed")
      {_status, output} -> unavailable(gh_reason(output))
    end
  end

  defp decode_pull_requests(output) do
    case Jason.decode(output) do
      {:ok, prs} when is_list(prs) ->
        %{available: true, reason: nil, items: Enum.map(prs, &render_pr/1)}

      _undecodable ->
        unavailable("gh returned output that could not be decoded")
    end
  end

  defp render_pr(pr) do
    files = Map.get(pr, "files", []) || []

    %{
      number: Map.get(pr, "number"),
      title: Map.get(pr, "title"),
      branch: Map.get(pr, "headRefName"),
      base: Map.get(pr, "baseRefName"),
      draft: Map.get(pr, "isDraft", false),
      files_changed: length(files)
    }
  end

  defp unavailable(reason), do: %{available: false, reason: reason, items: []}

  defp gh_reason(output) do
    trimmed = output |> String.trim() |> String.split("\n") |> List.first()

    cond do
      trimmed in [nil, ""] -> "gh could not list PRs"
      String.contains?(trimmed, "auth") -> "gh is not authenticated: #{trimmed}"
      true -> "gh could not list PRs: #{trimmed}"
    end
  end

  # -- Dependency drift -------------------------------------------------------

  defp repo_drift(nil, _package, _latest), do: drift(nil, nil, nil)

  defp repo_drift(lock, package, latest) do
    pinned = MigratorChain.locked_version_from_source(lock, package)
    requirement = transitive_requirement_in(lock, package)
    drift(pinned, latest, requirement)
  end

  # A repo does not record its own top-level requirement in mix.lock, only its
  # transitive dependencies do. The nearest machine-readable requirement is what
  # any locked package pins for `package`; absent that, the cap is unknown.
  defp transitive_requirement_in(lock, package) do
    name = Regex.escape(to_string(package))

    case Regex.run(~r/\{:#{name},\s*"([^"]+)"/, lock) do
      [_all, requirement] -> requirement
      nil -> nil
    end
  end

  # -- Migrator chain ---------------------------------------------------------

  defp migrator(path, lock) do
    migrations_path = Path.join([path, "priv", "repo", "migrations"])
    wrappers = MigratorChain.scan_path(migrations_path)
    resolution = MigratorChain.resolve_target(path)

    direct = MigratorChain.applied_version(wrappers)
    indirect = if lock, do: indirect_floor(lock), else: 0
    effective = max(direct, indirect)

    %{
      target: resolution.version,
      target_source: to_string(resolution.source),
      direct_applied: direct,
      indirect_floor: indirect,
      effective_applied: effective,
      status: migrator_status(effective, resolution),
      wrappers: wrappers
    }
  end

  defp migrator_status(_effective, %{confidence: :assumed}), do: "unknown"
  defp migrator_status(effective, %{version: target}) when effective >= target, do: "current"
  defp migrator_status(_effective, _resolution), do: "behind"

  # -- Blocked-by -------------------------------------------------------------

  defp blocked_by(nil, _package, _latest),
    do: %{available: false, reason: "no mix.lock", items: []}

  defp blocked_by(_lock, _package, nil),
    do: %{available: false, reason: "no latest version supplied to compare against", items: []}

  defp blocked_by(lock, package, latest),
    do: %{available: true, reason: nil, items: blockers(lock, package, latest)}

  # -- Local vs origin --------------------------------------------------------

  defp git_status(path, package, latest, fetch?, runner) do
    branch = git_branch(path, runner)
    dirty? = git_dirty?(path, runner)
    if fetch?, do: runner.("git", ["-C", path, "fetch", "--quiet"], path)

    {origin?, ahead_behind} = git_ahead_behind(path, branch, runner)
    origin_pin = git_origin_pin(path, branch, package, runner)
    local_pin = local_pin(path, package)

    %{
      branch: branch,
      dirty: dirty?,
      has_origin: origin?,
      ahead: elem_or_nil(ahead_behind, 1),
      behind: elem_or_nil(ahead_behind, 0),
      local_pin: local_pin,
      origin_pin: origin_pin,
      diverges_from_origin: diverges?(ahead_behind, local_pin, origin_pin),
      answered_from: if(origin?, do: "origin", else: "local checkout (no origin reachable)"),
      latest: latest
    }
  end

  defp git_branch(path, runner) do
    case runner.("git", ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"], path) do
      {0, output} -> String.trim(output)
      _unavailable -> nil
    end
  end

  defp git_dirty?(path, runner) do
    case runner.("git", ["-C", path, "status", "--porcelain"], path) do
      {0, output} -> String.trim(output) != ""
      _unavailable -> nil
    end
  end

  defp git_ahead_behind(_path, nil, _runner), do: {false, nil}

  defp git_ahead_behind(path, branch, runner) do
    ref = "origin/#{branch}"
    args = ["-C", path, "rev-list", "--left-right", "--count", "#{ref}...HEAD"]

    case runner.("git", args, path) do
      {0, output} -> {true, parse_ahead_behind(output)}
      _no_origin -> {false, nil}
    end
  end

  defp git_origin_pin(_path, nil, _package, _runner), do: nil

  defp git_origin_pin(path, branch, package, runner) do
    case runner.("git", ["-C", path, "show", "origin/#{branch}:mix.lock"], path) do
      {0, output} -> MigratorChain.locked_version_from_source(output, package)
      _no_origin -> nil
    end
  end

  defp local_pin(path, package) do
    case File.read(Path.join(path, "mix.lock")) do
      {:ok, lock} -> MigratorChain.locked_version_from_source(lock, package)
      {:error, _reason} -> nil
    end
  end

  defp diverges?(ahead_behind, local_pin, origin_pin) do
    moved? =
      case ahead_behind do
        {behind, ahead} -> behind > 0 or ahead > 0
        _none -> false
      end

    pins_disagree? = not is_nil(origin_pin) and local_pin != origin_pin

    moved? or pins_disagree?
  end

  defp elem_or_nil(nil, _index), do: nil
  defp elem_or_nil(tuple, index), do: elem(tuple, index)

  # -- Summary ----------------------------------------------------------------

  # An ordered "what's next", worst-cost first: something no command can fix
  # (blocked-by), then a requirement edit, then a migration to run, then a stale
  # checkout to reconcile, then work already in flight.
  defp summarize(reports, package, latest) do
    []
    |> add_lines(blocked_lines(reports))
    |> add_lines(requirement_lines(reports, package))
    |> add_lines(behind_lines(reports))
    |> add_lines(divergence_lines(reports))
    |> add_lines(pr_lines(reports))
    |> add_lines(gh_gap_lines(reports))
    |> Enum.reverse()
    |> then(&(&1 ++ headline(reports, package, latest)))
  end

  defp add_lines(acc, lines), do: Enum.reduce(lines, acc, &[&1 | &2])

  defp blocked_lines(reports) do
    for r <- reports, %{package: p, version: v, requirement: req} <- r.blocked_by.items do
      "BLOCKED: #{r.repo} cannot upgrade until #{p} #{v} (pins #{req}) ships a release"
    end
  end

  defp requirement_lines(reports, package) do
    for r <- reports, r.drift.verdict == :requirement_blocks do
      "REQUIREMENT: #{r.repo} pins #{package} #{r.drift.requirement} (#{r.drift.cap} cap), " <>
        "which refuses #{r.drift.latest}; edit the requirement"
    end
  end

  defp behind_lines(reports) do
    for r <- reports, r.migrator.status == "behind" do
      "MIGRATOR: #{r.repo} is at v#{r.migrator.effective_applied} of v#{r.migrator.target}; " <>
        "run mix defdo.saas.migrations"
    end
  end

  defp divergence_lines(reports) do
    for r <- reports, r.git.diverges_from_origin do
      "DIVERGED: #{r.repo} (#{r.git.branch}) differs from origin " <>
        "(ahead #{r.git.ahead || 0}, behind #{r.git.behind || 0}); reconcile before trusting it"
    end
  end

  defp pr_lines(reports) do
    for r <- reports, r.pull_requests.available, pr <- r.pull_requests.items do
      "PR: #{r.repo} ##{pr.number} #{pr.title} (#{pr.branch} -> #{pr.base})" <>
        if(pr.draft, do: " [draft]", else: "")
    end
  end

  defp gh_gap_lines(reports) do
    for r <- reports, not r.pull_requests.available do
      "UNKNOWN PRs: #{r.repo} — #{r.pull_requests.reason}"
    end
  end

  defp headline(reports, package, latest) do
    count = length(reports)
    latest_note = if latest, do: " against #{package} #{latest}", else: ""
    ["#{count} repo(s) under review#{latest_note}."]
  end

  # -- Default runner ---------------------------------------------------------

  defp system_runner(cmd, args, cd) do
    {output, status} = System.cmd(cmd, args, stderr_to_stdout: true, cd: cd)
    {status, output}
  rescue
    _missing_binary -> {:enoent, ""}
  end
end

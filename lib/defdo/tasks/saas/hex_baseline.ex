defmodule Defdo.Tasks.Saas.HexBaseline do
  @moduledoc """
  Resolves the *currently published* version of a stack package from the
  private `defdo` Hex organization, so `mix defdo.saas.doctor` can compare an
  app's declared requirement against reality instead of a hardcoded number
  that goes stale the moment the estate ships a release this package's
  source was never updated to know about.

  ## Why shell out to `mix hex.info`

  The Hex archive (`Hex.API.Package`, etc.) is only added to the code path
  when Mix dispatches a task whose name is already known to belong to the
  `hex` namespace -- a task compiled into a consuming app, like this one, does
  not have it available even though the archive is installed. Shelling out to
  `mix hex.info <package> --organization defdo` gets a real `hex.*` task
  dispatch and reuses whatever Hex auth the host project already has (the
  same `mix hex.organization auth defdo --key $HEX_ORG_TOKEN` this project's
  own CI runs), so nothing new needs to be authenticated or installed.

  ## The failure contract

  Every path that is not a clean, parseable success returns `{:error,
  reason}`. Offline, an expired session, a missing organization key, a
  private package that 404s because the caller cannot see it (Hex answers an
  unauthorized request for a private-org package the same way it answers a
  nonexistent one) -- none of these get to look like "the package doesn't
  exist" or "the app is behind". The caller renders `{:error, _}` as a
  WARNING that the version-pin check did not run, never as a stale fact and
  never as a pass: an un-run check is unknown, and unknown must fail
  `--strict` the same way a real problem does.
  """

  @organization "defdo"
  @default_timeout_ms 10_000

  # `mix hex.info` authenticates with the Hex *user session* in
  # `~/.hex/hex.config`, which is a different credential path from the repo
  # key `mix deps.get` uses. A caller can therefore resolve every private dep
  # fine while `hex.info` answers "No package with name X" for all of them.
  # These are the variables an operator (or CI) already exports for
  # `mix hex.organization auth defdo --key $HEX_ORG_TOKEN`; the first one
  # present is forwarded to the subprocess as `HEX_API_KEY`, which Hex honours
  # ahead of the expired session. Nothing is read from dotfiles and the value
  # is never logged.
  @credential_vars ["HEX_API_KEY", "HEX_ORG_TOKEN"]

  @typedoc "Why a package's current release could not be resolved."
  @type reason ::
          :timeout
          | :expired_session
          | {:exit, non_neg_integer(), String.t()}
          | String.t()

  @type resolution :: {:ok, Version.t()} | {:error, reason()}

  @doc """
  Resolves the current published version of every name in `names`.

  Each package is queried exactly once, however many times the resulting map
  is read afterward -- callers should resolve the whole set up front (once
  per `mix defdo.saas.doctor` run) and thread the map through, rather than
  calling this once per dependency check.

  `opts[:fetch]` overrides how a single package's raw `mix hex.info` output
  is obtained. It defaults to the real shell-out and is the seam tests use to
  avoid the network entirely -- see `resolve/2`.
  """
  @spec resolve_all([atom()], keyword()) :: %{atom() => resolution()}
  def resolve_all(names, opts \\ []) when is_list(names) do
    Map.new(names, &{&1, resolve(&1, opts)})
  end

  @doc """
  Resolves the current published version of a single package.

      iex> fetch = fn :ok_pkg -> {:ok, 0, "Recent releases:\\n  1.2.3 (2026-01-01)\\n  1.2.2 (2025-01-01)\\n\\n"} end
      iex> {:ok, version} = Defdo.Tasks.Saas.HexBaseline.resolve(:ok_pkg, fetch: fetch)
      iex> to_string(version)
      "1.2.3"

      iex> fetch = fn :missing_pkg -> {:ok, 1, "No package with name missing_pkg\\n"} end
      iex> Defdo.Tasks.Saas.HexBaseline.resolve(:missing_pkg, fetch: fetch)
      {:error, {:exit, 1, "No package with name missing_pkg"}}

      iex> fetch = fn :offline_pkg -> {:error, :nxdomain} end
      iex> Defdo.Tasks.Saas.HexBaseline.resolve(:offline_pkg, fetch: fetch)
      {:error, :nxdomain}

      iex> expired = "Your authentication session has expired and could not be refreshed.\\nNo package with name any_pkg\\n"
      iex> fetch = fn :any_pkg -> {:ok, 1, expired} end
      iex> Defdo.Tasks.Saas.HexBaseline.resolve(:any_pkg, fetch: fetch)
      {:error, :expired_session}
  """
  @spec resolve(atom(), keyword()) :: resolution()
  def resolve(name, opts \\ []) when is_atom(name) do
    fetch = Keyword.get(opts, :fetch) || fn n -> default_fetch(n, opts) end

    case fetch.(name) do
      {:ok, 0, output} -> parse_latest(output)
      {:ok, status, output} -> {:error, exit_reason(status, output)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  # The real fetch: shells out to `mix hex.info`, bounded by a timeout so an
  # unreachable registry degrades this check instead of hanging the whole
  # doctor run. `System.cmd/3` has no timeout of its own, so the call runs in
  # a supervised Task and is abandoned (not killed -- the OS process may
  # linger) if it does not answer in time; a lingering `mix hex.info` is a far
  # smaller problem than a doctor invocation that never returns.
  defp default_fetch(name, opts) do
    cmd = Keyword.get(opts, :cmd, &System.cmd/3)
    env = credential_env(Keyword.get(opts, :getenv, &System.get_env/1))

    task =
      Task.async(fn ->
        cmd.("mix", ["hex.info", to_string(name), "--organization", @organization],
          stderr_to_stdout: true,
          env: env
        )
      end)

    case Task.yield(task, @default_timeout_ms) do
      {:ok, {output, status}} -> {:ok, status, output}
      nil -> {:error, :timeout}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  @doc """
  The `env` this module forwards to `mix hex.info`, given a `System.get_env/1`-
  shaped function.

  Returns `[{"HEX_API_KEY", token}]` for the first of #{inspect(@credential_vars)}
  the ambient environment defines with a non-blank value, and `[]` when it
  defines none -- in which case `mix hex.info` falls back to whatever session
  `~/.hex/hex.config` holds, exactly as before. The token itself is never
  logged, rendered, or included in any finding.
  """
  @spec credential_env((String.t() -> String.t() | nil)) :: [{String.t(), String.t()}]
  def credential_env(getenv \\ &System.get_env/1) when is_function(getenv, 1) do
    @credential_vars
    |> Enum.map(getenv)
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
    |> case do
      nil -> []
      token -> [{"HEX_API_KEY", String.trim(token)}]
    end
  end

  # A nonzero `mix hex.info` is ambiguous by default: an unauthenticated
  # caller gets "No package with name X" for every private package, published
  # or not. When the output carries Hex's expired-session notice we know which
  # one it was, and reporting it as a missing package would send the operator
  # hunting for a package that is right there in their `mix.lock`.
  defp exit_reason(status, output) do
    stripped = strip_ansi(output)

    if stripped =~ ~r/authentication session has expired/i do
      :expired_session
    else
      {:exit, status, first_line(output)}
    end
  end

  # `mix hex.info` often prints a colored warning line before the actual
  # error (an expired session notice ahead of "No package with name ...", for
  # instance) -- verified against this project's own environment, where the
  # local Hex session had genuinely expired. The *last* non-blank line is the
  # specific reason, and ANSI color codes have no business in a doctor
  # report.
  defp first_line(output) do
    output
    |> strip_ansi()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> to_string()
  end

  defp strip_ansi(text), do: Regex.replace(~r/\e\[[0-9;]*m/, text, "")

  # `mix hex.info <pkg>` prints, on success:
  #
  #   Config: {:pkg, "~> 1.2", organization: :defdo}
  #   Locked version: 1.2.2
  #
  #   Recent releases:
  #     1.2.3 (2026-01-01)
  #     1.2.2 (2025-06-01)
  #     ...
  #
  # Parsed textually rather than via any Hex client struct, so this keeps
  # working across Hex CLI versions as long as the human-readable shape does.
  defp parse_latest(output) do
    case String.split(output, "Recent releases:", parts: 2) do
      [_before, after_marker] ->
        # Everything after the marker, line by line -- blank lines, the
        # truncating "...", and later sections like "Downloads:" all fail
        # `extract_version/1`'s pattern harmlessly, so there is no need to
        # find where the release list "ends".
        after_marker
        |> String.split("\n")
        |> Enum.flat_map(&extract_version/1)
        |> pick_latest()

      [_no_marker] ->
        {:error, first_line(output)}
    end
  end

  defp extract_version(line) do
    case Regex.run(~r/^\s+(\S+)\s+\(/, line) do
      [_all, token] ->
        case Version.parse(token) do
          {:ok, version} -> [version]
          :error -> []
        end

      nil ->
        []
    end
  end

  defp pick_latest([]), do: {:error, :no_releases_found}

  defp pick_latest(versions) do
    stable = Enum.reject(versions, &(&1.pre != []))
    candidates = if stable == [], do: versions, else: stable

    {:ok, Enum.max(candidates, Version)}
  end
end

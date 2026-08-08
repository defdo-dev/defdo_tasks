defmodule Defdo.Tasks.MCP.Server do
  @moduledoc """
  Minimal stdio MCP server exposing the defdo SaaS catalog as read-only tools.

  This mirrors `Defdo.Theme.Components.MCP.Server` (same JSON-RPC framing,
  the same `tools/list` + `tools/call` shape, the same error codes) rather
  than inventing a second style. See issue #4 for why the surface stops here:
  `Defdo.Tasks.Saas.Stack`, `Defdo.Tasks.Saas.MigratorChain` and
  `Defdo.Tasks.Saas.Audit` are pure functions over a catalog and a project
  tree, so asking them a question changes nothing. `mix defdo.saas.install`
  and `mix defdo.saas.migrations` mutate files and stay Mix-only on purpose;
  wrapping them here would give the estate a second interface to the same
  behaviour, which is the exact duplication #4 exists to avoid.

  Deliberately narrower than the precedent: no `resources/*` handlers. Nothing
  in issue #4 asked for a resource surface, and adding one un-asked-for is the
  same mistake as a fourth tool.
  """

  alias Defdo.Tasks.Saas.{Audit, MigratorChain, Stack}

  @protocol_version "2025-06-18"

  @known_tiers ~w(core recommended optional)

  @tools [
    %{
      "name" => "defdo_saas.stack",
      "description" =>
        "List the defdo SaaS dependency stack: what packages make up a defdo SaaS app, " <>
          "per tier, with the version requirement and the reason each is there.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "tiers" => %{
            "type" => "array",
            "items" => %{"type" => "string", "enum" => @known_tiers},
            "description" =>
              "Optional tier filter. Omit for the default install set (core + recommended). " <>
                "An unknown tier is an error naming the real ones."
          },
          "all" => %{
            "type" => "boolean",
            "description" =>
              "When true, ignore `tiers` and return every dependency the stack knows about " <>
                "(Stack.all/0), including packages `select/1` would exclude for not being " <>
                "published to Hex yet."
          }
        },
        "additionalProperties" => false
      }
    },
    %{
      "name" => "defdo_saas.migrator_chain",
      "description" =>
        "Report the tenant migrator wrapper chain for an app: which wrappers it has, which " <>
          "target version it should reach, and what is missing, floating, asymmetric or in " <>
          "prefix conflict.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "root" => %{
            "type" => "string",
            "description" => "The project root to read migrations from. Defaults to \".\"."
          },
          "migrations_path" => %{
            "type" => "string",
            "description" =>
              "Defaults to \"<root>/priv/repo/migrations\", the same default " <>
                "`mix defdo.saas.doctor` uses."
          },
          "migrator" => %{
            "type" => "string",
            "description" =>
              "The migrator module to scan for, defaults to " <>
                "\"#{MigratorChain.default_migrator()}\"."
          },
          "prefix" => %{
            "type" => "string",
            "description" =>
              "The Postgres schema prefix the app expects. When given, wrappers targeting a " <>
                "different prefix are reported under `prefix_conflicts`. Omitted by default, " <>
                "in which case that check is skipped rather than run against a guessed prefix."
          },
          "defdo_tenant_path" => %{
            "type" => "string",
            "description" =>
              "Path to the defdo_tenant package root, for an app that resolves it through a " <>
                "`path:` dependency rather than `<root>/deps/defdo_tenant`. When given, the " <>
                "target version is read from `<path>/lib/defdo/migrator.ex`."
          }
        },
        "additionalProperties" => false
      }
    },
    %{
      "name" => "defdo_saas.audit",
      "description" =>
        "Run the read-only findings `mix defdo.saas.doctor` wraps: the migrator chain, the " <>
          "stack dependency set, and `defdo_compiled_config.exs` drift, for an app at a given " <>
          "root.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "root" => %{
            "type" => "string",
            "description" => "The project root to audit. Defaults to \".\"."
          },
          "migrations_path" => %{
            "type" => "string",
            "description" => "Defaults to \"<root>/priv/repo/migrations\"."
          },
          "config_path" => %{
            "type" => "string",
            "description" => "Defaults to \"<root>/config\"."
          },
          "deps" => %{
            "type" => "array",
            "description" =>
              "The app's declared dependencies, since `Audit.run/2` is a pure function over a " <>
                "project tree and does not read a mix.exs. Omit to check as if none were " <>
                "declared, which reports every core stack package as missing.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "name" => %{"type" => "string"},
                "requirement" => %{"type" => "string"},
                "organization" => %{"type" => "string"}
              },
              "required" => ["name"],
              "additionalProperties" => false
            }
          },
          "strict" => %{
            "type" => "boolean",
            "description" =>
              "When true, `exit_status` in the result also fails on warnings, matching " <>
                "`mix defdo.saas.doctor --strict`."
          }
        },
        "additionalProperties" => false
      }
    }
  ]

  defstruct default_root: "."

  @doc """
  Builds server state. `:default_root` is used by a tool call whose arguments
  omit `root`; each call may still override it explicitly.
  """
  def new(opts \\ []) do
    %__MODULE__{default_root: Keyword.get(opts, :default_root, ".")}
  end

  def tools, do: @tools

  def handle_message(%{"method" => "notifications/initialized"}, state) do
    {:noreply, state}
  end

  def handle_message(%{"id" => id, "method" => "initialize"} = request, state) do
    params = Map.get(request, "params", %{})
    client_protocol = Map.get(params, "protocolVersion")

    result = %{
      "protocolVersion" => client_protocol || @protocol_version,
      "capabilities" => %{
        "tools" => %{"listChanged" => false}
      },
      "serverInfo" => %{
        "name" => "defdo_tasks",
        "version" => Application.spec(:defdo_tasks, :vsn) |> to_string()
      }
    }

    {response(id, result), state}
  end

  def handle_message(%{"id" => id, "method" => "tools/list"}, state) do
    {response(id, %{"tools" => @tools}), state}
  end

  def handle_message(%{"id" => id, "method" => "tools/call"} = request, state) do
    params = Map.get(request, "params", %{})
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{}) || %{}

    case call_tool(name, arguments, state) do
      {:ok, result} -> {response(id, result), state}
      {:error, code, message, data} -> {error_response(id, code, message, data), state}
    end
  end

  def handle_message(%{"id" => id, "method" => method}, state) do
    {error_response(id, -32_601, "Method not found", %{"method" => method}), state}
  end

  def handle_message(_message, state), do: {:noreply, state}

  defp call_tool("defdo_saas.stack", arguments, _state) do
    case selected_deps(arguments) do
      {:ok, deps} ->
        tool_result(%{
          "dependencies" => Enum.map(deps, &render_dep/1),
          "tiers" => @known_tiers
        })

      {:error, unknown} ->
        {:error, -32_602, "Unknown tier", %{"requested" => unknown, "tiers" => @known_tiers}}
    end
  end

  defp call_tool("defdo_saas.migrator_chain", arguments, state) do
    with {:ok, root} <- resolve_root(arguments, state) do
      migrator = Map.get(arguments, "migrator", MigratorChain.default_migrator())
      migrations_path = Map.get(arguments, "migrations_path", default_migrations_path(root))

      wrappers = MigratorChain.scan_path(migrations_path, migrator)
      resolution = MigratorChain.resolve_target(root, resolve_opts(arguments))

      tool_result(%{
        "root" => root,
        "migrations_path" => migrations_path,
        "migrator" => migrator,
        "target_version" => resolution.version,
        "target_version_source" => to_string(resolution.source),
        "target_version_confidence" => to_string(resolution.confidence),
        "resolved_dependency" => to_string(resolution.dependency),
        "resolved_version" => resolution.dependency_version,
        "wrappers" => wrappers,
        "status" => render_status(wrappers, resolution),
        "asymmetric" => MigratorChain.asymmetric(wrappers),
        "prefix_checked" => Map.has_key?(arguments, "prefix"),
        "prefix_conflicts" => prefix_conflicts(wrappers, Map.get(arguments, "prefix"))
      })
    end
  end

  defp call_tool("defdo_saas.audit", arguments, state) do
    with {:ok, root} <- resolve_root(arguments, state),
         {:ok, deps} <- parse_deps(Map.get(arguments, "deps", [])) do
      migrations_path = Map.get(arguments, "migrations_path", default_migrations_path(root))
      config_path = Map.get(arguments, "config_path", Path.join(root, "config"))
      strict? = Map.get(arguments, "strict", false)

      findings =
        Audit.run(root,
          migrations_path: migrations_path,
          config_path: config_path,
          deps: deps
        )

      tool_result(%{
        "root" => root,
        "migrations_path" => migrations_path,
        "config_path" => config_path,
        "findings" => findings,
        "counts" => Enum.frequencies_by(findings, & &1.severity),
        "exit_status" => Audit.exit_status(findings, strict: strict?)
      })
    end
  end

  defp call_tool(name, _arguments, _state) do
    {:error, -32_602, "Unknown tool", %{"name" => name}}
  end

  # `Stack.all/0` and `Stack.select/1` disagree on purpose: `select/1` also
  # drops unpublished packages unless their tier was asked for by name.
  # `all: true` is the escape hatch to see the roster `select/1` would hide.
  defp selected_deps(%{"all" => true}), do: {:ok, Stack.all()}

  defp selected_deps(arguments) do
    case Map.get(arguments, "tiers") do
      nil ->
        {:ok, Stack.select()}

      tiers when is_list(tiers) ->
        case Enum.reject(tiers, &(&1 in @known_tiers)) do
          [] -> {:ok, Stack.select(Enum.map(tiers, &String.to_existing_atom/1))}
          unknown -> {:error, unknown}
        end
    end
  end

  defp render_dep(dep) do
    %{
      "name" => dep.name,
      "requirement" => dep.requirement,
      "tier" => dep.tier,
      "hex" => dep.hex,
      "published" => dep.published?,
      "why" => dep.why,
      "source" => Stack.to_source(dep)
    }
  end

  defp resolve_root(arguments, state) do
    root = Map.get(arguments, "root", state.default_root)

    if File.dir?(root) do
      {:ok, root}
    else
      {:error, -32_002, "Project root not found", %{"root" => root}}
    end
  end

  defp default_migrations_path(root), do: Path.join([root, "priv", "repo", "migrations"])

  defp resolve_opts(arguments) do
    case Map.get(arguments, "defdo_tenant_path") do
      nil -> []
      path -> [package_path: path]
    end
  end

  # An assumed target must not be dressed up as a status: `status/2` would report
  # `current`/`behind`/`missing` against a number that was never read, which is
  # exactly the confident-wrong answer issue #7 exists to stop. Report `unknown`
  # with the reason, still surfacing how far the wrappers reach.
  defp render_status(wrappers, %{confidence: :assumed} = resolution) do
    %{
      "kind" => "unknown",
      "reason" => resolution.reason,
      "applied" => MigratorChain.applied_version(wrappers)
    }
  end

  defp render_status(wrappers, %{version: target}) do
    render_status(MigratorChain.status(wrappers, target))
  end

  # `MigratorChain.status/2`'s typespec includes `:unknown`, but its body never
  # returns it (verified by reading the `cond` in `status/2`) -- reserved for a
  # caller that never arrives one. Not handled here: an unmatched status would
  # be a real gap to know about, not one to paper over with a clause that
  # `--warnings-as-errors` would then flag as dead code.
  defp render_status(:current), do: %{"kind" => "current"}

  defp render_status({:behind, applied, target}),
    do: %{"kind" => "behind", "applied" => applied, "target" => target}

  defp render_status({:floating, files}), do: %{"kind" => "floating", "files" => files}
  defp render_status({:missing, target}), do: %{"kind" => "missing", "target" => target}

  defp prefix_conflicts(_wrappers, nil), do: nil
  defp prefix_conflicts(wrappers, prefix), do: MigratorChain.prefix_conflicts(wrappers, prefix)

  defp parse_deps(deps) when is_list(deps) do
    deps
    |> Enum.reduce_while({:ok, []}, fn dep, {:ok, acc} ->
      case parse_dep(dep) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, reason} -> {:error, -32_602, "Invalid dependency entry", reason}
    end
  end

  defp parse_dep(%{"name" => name} = dep) when is_binary(name) and name != "" do
    opts =
      case Map.get(dep, "organization") do
        nil -> []
        org -> [organization: String.to_atom(org)]
      end

    case Map.get(dep, "requirement") do
      nil -> {:ok, {String.to_atom(name), opts}}
      requirement -> {:ok, {String.to_atom(name), requirement, opts}}
    end
  end

  defp parse_dep(dep), do: {:error, %{"entry" => dep}}

  defp tool_result(payload) do
    {:ok,
     %{
       "content" => [
         %{
           "type" => "text",
           "text" => Jason.encode!(payload, pretty: true)
         }
       ],
       "isError" => false
     }}
  end

  defp response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_response(id, code, message, data) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message, "data" => data}
    }
  end
end

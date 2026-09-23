defmodule Fleet.MCP.PodTools.Probe do
  @moduledoc """
  Dispatches a named project workflow and returns its LCARS-PROBE facts without
  interpreting verdicts. Public names map to workflow filenames in `@probes`; adding
  a name still requires updating that map as well as supplying the workflow.

  Repository identity comes from PodResolver and the PR number from PodId. This
  module checks the PR identity shape, not role capabilities. References come from
  the forge and declarations from the delivered SHA, never caller overrides.
  Other inputs are stringified and forwarded without checking workflow declarations.

  Execution status accompanies facts, so an interrupted run without measurements
  remains distinguishable from a completed probe. Workflow success is not enforced here.
  """

  # Workflows live in the project. Keep their probe- naming distinct from the
  # CI / * contexts required by Onboard.Faces main-branch protection.
  @probes %{
    "test-relevance" => "probe-test-relevance.yml"
  }

  @fact_prefix "LCARS-PROBE"
  @poll_ms 1_000
  @max_wait_ms 120_000

  @doc "Les noms de sondes que le rail sait résoudre."
  @spec known() :: [String.t()]
  def known, do: Map.keys(@probes)

  @doc """
  Runs a known probe for a PR-bound pod and returns facts plus execution metadata.
  """
  @spec run(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(pod_id, probe, inputs \\ %{}, opts \\ [])
      when is_binary(pod_id) and is_binary(probe) and is_map(inputs) do
    with {:ok, workflow} <- resolve_probe(probe),
         {:ok, %{repo: repo}} <- identity(pod_id, opts),
         {:ok, pr} <- pr_of(pod_id, repo),
         {:ok, refs} <- forge().pr_refs(repo, pr, forge_opts(opts)),
         {:ok, declared} <- declarations(repo, refs.head_sha, opts),
         {:ok, %{run_id: run_id}} <-
           forge_actions().dispatch_workflow(
             repo,
             workflow,
             refs.base_ref,
             rail_inputs(refs, declared, inputs),
             forge_opts(opts)
           ),
         {:ok, logs, run_state} <- await_logs(repo, run_id, opts) do
      facts =
        logs
        |> facts()
        |> Map.merge(run_state)
        |> Map.put("probe", probe)
        |> Map.put("run_id", run_id)

      {:ok, facts}
    end
  end

  # ── Résolution ─────────────────────────────────────────────────────────────────────────────────

  defp resolve_probe(probe) do
    case Map.fetch(@probes, probe) do
      {:ok, wf} -> {:ok, wf}
      # Le refus ÉNUMÈRE, parce qu'un refus qui ne dit pas quoi écrire à la place renvoie l'appelant
      # par le même appel (même leçon que `declarable_card/3`).
      :error -> {:error, {:unknown_probe, probe, known()}}
    end
  end

  # Dispatched pods can carry repo_id without repo; resolve the numeric id through
  # the forge instead of rejecting the roles this tool serves.
  defp identity(pod_id, opts) do
    case Fleet.MCP.PodTools.PodResolver.resolved().(pod_id) do
      {:ok, %{repo: repo}} when is_binary(repo) and repo != "" ->
        {:ok, %{repo: repo}}

      {:ok, %{repo_id: id}} when is_integer(id) and id > 0 ->
        case forge().repo_full_name(id, forge_opts(opts)) do
          {:ok, full} -> {:ok, %{repo: full}}
          {:error, _} = err -> err
        end

      {:ok, _unbound} ->
        {:error, :repo_unbound}

      {:error, _} = err ->
        err
    end
  end

  # Parse the PR from the pod identity; issue-bound pods cannot select an arbitrary PR.
  defp pr_of(pod_id, repo) do
    case Fleet.PodId.parse_ref(pod_id, repo) do
      {:ok, {:pr, n}} -> {:ok, n}
      {:ok, {:issue, _}} -> {:error, :not_a_deliverable_judge}
      :error -> {:error, :pr_unresolvable}
    end
  end

  # ── Déclarations du projet ─────────────────────────────────────────────────────────────────────

  @doc """
  Reads exact `## Harness` and `## Test` sections from CLAUDE.md at `ref`.
  `run/4` passes the delivered SHA so declarations can change with the PR.
  Missing file or section yields empty strings; other forge errors propagate.
  """
  @spec declarations(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def declarations(repo, ref, opts \\ []) do
    case forge().get_file(repo, "CLAUDE.md", Keyword.put(forge_opts(opts), :ref, ref)) do
      {:ok, %{content: md}} ->
        {:ok, %{harness: section(md, "Harness"), test_cmd: command(md)}}

      {:error, :not_found} ->
        {:ok, %{harness: "", test_cmd: ""}}

      {:error, _} = err ->
        err
    end
  end

  # RepoSections has a separate whitelist for prompt content and excludes Harness.
  # Scan headings outside backtick fences but retain fenced section bodies: removing
  # all code blocks first would also erase a legitimate fenced test command.
  defp section(md, name), do: md |> raw_section(name) |> strip_fences()

  # `## Test` is read by two parties: producers get the whole section as documentation, the probe
  # needs a command. The command is the section's fenced code; prose around it is documentation.
  # A section without any fence is the command as a whole (the template's original contract).
  # Prose once reached the probe as a command, and an apostrophe in it broke every probe run.
  defp command(md) do
    raw = raw_section(md, "Test")

    case fenced_lines(raw) do
      [] -> strip_fences(raw)
      lines -> lines |> Enum.map_join("\n", &String.trim_trailing/1) |> String.trim()
    end
  end

  defp fenced_lines(raw) do
    raw
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {acc, inside?} ->
      cond do
        String.starts_with?(String.trim(line), "```") -> {acc, not inside?}
        inside? -> {[line | acc], inside?}
        true -> {acc, inside?}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp raw_section(md, name) do
    md
    |> String.split("\n")
    |> Enum.reduce({[], false, :before}, &scan_line(&1, &2, name))
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.trim()
  end

  defp scan_line(_line, {acc, in_fence?, :done}, _name), do: {acc, in_fence?, :done}

  defp scan_line(line, {acc, in_fence?, state}, name) do
    fence? = String.starts_with?(String.trim_leading(line), "```")
    next_fence? = if fence?, do: not in_fence?, else: in_fence?
    heading? = not in_fence? and not fence? and String.starts_with?(line, "## ")

    case {state, heading?} do
      {:capturing, true} -> {acc, in_fence?, :done}
      {:capturing, false} -> {[line | acc], next_fence?, :capturing}
      {:before, true} -> {acc, in_fence?, if(ours?(line, name), do: :capturing, else: :before)}
      {:before, false} -> {acc, next_fence?, :before}
    end
  end

  # Match the entire heading: a word boundary would also accept ## Test suite.
  defp ours?(line, name), do: String.trim_trailing(line) == "## " <> name

  # Strip backtick delimiters, preserving newlines: joining make build and make test
  # with a space would turn two commands into one. Harness paths tolerate either whitespace.
  defp strip_fences(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim(&1), "```"))
    |> Enum.map_join("\n", &String.trim_trailing/1)
    |> String.trim()
  end

  # Computed inputs override caller keys so a judge cannot choose a favorable comparison base.
  defp rail_inputs(refs, declared, judge_inputs) do
    judge_inputs
    |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)
    |> Map.merge(%{
      "base_sha" => refs.base_sha,
      "head_sha" => refs.head_sha,
      "harness" => declared.harness,
      "test_cmd" => declared.test_cmd
    })
  end

  # ── Attente et lecture ─────────────────────────────────────────────────────────────────────────

  # Poll within the tool call, not the shared Pilot tick. The deadline is checked
  # between forge calls; it does not interrupt a blocked call.
  defp await_logs(repo, run_id, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :max_wait_ms, @max_wait_ms)
    poll(repo, run_id, deadline, opts)
  end

  # Gitea 1.26.1 reports a finished run as `status: "completed"` and puts the outcome in
  # `conclusion` (capture: test/fixtures/forge/action_run.json). No other terminal status exists.
  defp poll(repo, run_id, deadline, opts) do
    case forge_actions().run(repo, run_id, forge_opts(opts)) do
      {:ok, %{"status" => "completed"} = run} ->
        # Preserve execution state even when no LCARS-PROBE lines were emitted.
        case forge_actions().run_logs(repo, run_id, forge_opts(opts)) do
          {:ok, logs} -> {:ok, logs, Map.take(run, ["status", "conclusion"])}
          {:error, _} = err -> err
        end

      {:ok, _still_going} ->
        if System.monotonic_time(:millisecond) >= deadline do
          # Timeout is an error, not evidence that the probe found nothing.
          {:error, {:probe_timeout, run_id}}
        else
          Process.sleep(Keyword.get(opts, :poll_ms, @poll_ms))
          poll(repo, run_id, deadline, opts)
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Extracts whitespace-separated key=value tokens after LCARS-PROBE in log lines.
  Later duplicate keys win; values remain strings and no verdict is inferred.
  """
  @spec facts(String.t()) :: map()
  def facts(logs) when is_binary(logs) do
    logs
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, @fact_prefix))
    |> Enum.flat_map(&pairs/1)
    |> Map.new()
  end

  defp pairs(line) do
    line
    |> String.split(@fact_prefix, parts: 2)
    |> List.last()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.flat_map(fn token ->
      case String.split(token, "=", parts: 2) do
        [k, v] when k != "" -> [{k, v}]
        _ -> []
      end
    end)
  end

  # Probe's forge seam is separate from Delegation's: these are independent call paths.
  defp forge, do: Application.get_env(:lcars_fleet, :mcp_probe_forge_client, Fleet.Forge.Client)

  # Shared with Pilot merge/promotion and CiGate for one Actions view across consumers.
  # This deliberate shared-domain key is the exception to owner-prefixed configuration.
  defp forge_actions,
    do: Application.get_env(:lcars_fleet, :forge_actions, Fleet.Forge.Client.Actions)

  defp forge_opts(opts), do: Keyword.get(opts, :forge_opts, [])
end

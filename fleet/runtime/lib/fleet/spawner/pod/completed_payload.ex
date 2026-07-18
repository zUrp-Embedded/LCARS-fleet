defmodule Fleet.Spawner.Pod.CompletedPayload do
  @moduledoc """
  PURE builder of the `pod.completed` event payload — island extracted from `Fleet.Spawner.Pod`.

  A single role: from the gen_statem `data` (READ, never mutated) + the received `result`, build the
  `pod.completed` payload map that `Pod` broadcasts via `Pod.Events.required_broadcast/2`. No own
  state, no Port, no timer, no FS write: only deterministic computation over the few read fields
  (`pod_id`, `issue_id`, `opts`, `cap_profile`, `pod_dir`). Twin of `Fleet.Pilot.BriefBuilder`
  (another pure payload builder extracted from its orchestrator).

  The builder is NOT housed in `Pod.Events`: that one is an ENVELOPE-only cluster (it builds the
  `%Fleet.Event{}` + broadcasts, it does NOT know the payload FORMAT). Separating keeps each
  boundary clean — `Events` = how we broadcast, `CompletedPayload` = what we put inside.

  ## `pod.completed` vocabulary (FROZEN — the StepRunConsumer depends on it)

  `pod.completed` is load-bearing LIFECYCLE: `Fleet.Pilot.StepRunConsumer` depends on it to finish
  the step_run. The payload KEYS (`pod_id`/`issue_id`/`result`/`workspace`/`base_sha`/`gate_base_sha`/
  `role`/`repository`/`remote`/`workflow_map`/`step`) are a contract — this module is the single
  source of their construction.

  ## Contract (called by `Pod`)

  - `build(data, result)` — returns the payload map. Single call site in the `:extracting` state
    (`Events.required_broadcast("pod.completed", CompletedPayload.build(data, result))`).

  ## Dependencies (siblings / downward — no cycle back to `Pod`)

  - `Fleet.Spawner.Pod.LaunchSpec.effective_project/2` (EFFECTIVE project, single source),
  - `Fleet.Spawner.Pod.Paths.pod_workspace_path/1` (single authority over the workspace subfolder),
  - `Fleet.CapProfile.name/1` (single source of the role carved at spawn).

  **Last revised**: 2026-07-18
  """

  alias Fleet.Spawner.Pod.LaunchSpec
  alias Fleet.Spawner.Pod.Paths

  @doc """
  Builds the `pod.completed` payload map from the gen_statem `data` (READ, never mutated) +
  the received `result`. Project pod (`repo_path` present) → embeds `workspace`/`base_sha`/
  `gate_base_sha`/`role` (+ `repository`/`remote` if `repo`); pod without project → bare payload
  (base). The workflow_map context (`workflow_map`+`step`) is carried ONLY IF the pod is spawned
  with those keys (`StepDispatcher` via `:workflow_map`/`:step`), else the payload is bare and the
  consumer no-ops the workflow_map navigation.
  """
  @spec build(map(), map()) :: map()
  def build(data, result) do
    base = %{
      "pod_id" => data.pod_id,
      "issue_id" => data.issue_id,
      "result" => result
    }

    opts = data.opts || []

    # Step-dispatch pod (assignee-driven). If it carries a PROJECT (cloned repo), the payload embeds the
    # end-of-step-run context: the StepRunConsumer consumer is stateless (the event carries the state).
    # Pod without project (memory-X, architect) → bare payload (base), filtered downstream.
    case LaunchSpec.effective_project(data.opts, data.cap_profile) do
      %{"repo_path" => rp} = proj when is_binary(rp) and rp != "" ->
        base
        |> Map.merge(%{
          # Single authority over the workspace subfolder (Pod.Paths), not a copied-around literal.
          "workspace" => Paths.pod_workspace_path(data.pod_dir),
          "base_sha" => proj["base_sha"],
          # Base of the delivery GATE, DECONFLICTED from the clone-base (`base_sha`) — a direct caller
          # can pin it (`gate_base_branch` → resolver → `gate_base_sha`); the forward path (build/rework)
          # equals it to `base_sha`. Fallback `base_sha`.
          "gate_base_sha" => proj["gate_base_sha"] || proj["base_sha"],
          "role" => Fleet.CapProfile.name(data.cap_profile)
        })
        |> maybe_put_repo(proj)
        |> maybe_put_workflow_map_ctx(opts)
        |> maybe_put_brief_provenance(opts)

      _ ->
        base
    end
  end

  # Brief provenance: the version pointer `{brief_sha, brief_ref}` (introducing commit + path) injected at spawn
  # (spawn_opts) travels ALL THE WAY HERE, next to `base_sha` — the two dispatch-time provenance
  # inputs of the provenance triplet, together. pod.completed → step_run → StepRunCompleter
  # assembles the triplet. Absent (brief not materialized / pod without dispatch) → payload
  # unchanged, never an invented sha.
  defp maybe_put_brief_provenance(payload, opts) do
    case Keyword.get(opts, :brief_sha) do
      sha when is_binary(sha) and sha != "" ->
        Map.merge(payload, %{"brief_sha" => sha, "brief_ref" => Keyword.get(opts, :brief_ref)})

      _ ->
        payload
    end
  end

  # workflow_map context (workflow_map+step) injected at spawn by StepDispatcher via `:workflow_map`/`:step`.
  # Lets the StepRunConsumer navigate the workflow_map. Absent (1-step workflow_map) → payload unchanged.
  defp maybe_put_workflow_map_ctx(payload, opts) do
    case {Keyword.get(opts, :workflow_map), Keyword.get(opts, :step)} do
      {p, s} when is_binary(p) and is_binary(s) ->
        Map.merge(payload, %{"workflow_map" => p, "step" => s})

      _ ->
        payload
    end
  end

  # Multi-project: embeds the project's REPO in `pod.completed` → the StepRunConsumer knows which
  # repo to act on + where to push. `"repository" => %{"full_name"}` = forge identifier; `"remote"` = the
  # push URL. Project without `"repo"` → payload unchanged → single-repo fallback of the StepRunConsumer.
  defp maybe_put_repo(payload, %{"repo" => repo} = proj) when is_binary(repo) and repo != "" do
    payload
    |> Map.put("repository", %{"full_name" => repo})
    |> maybe_put_remote(proj["repo_path"])
  end

  defp maybe_put_repo(payload, _proj), do: payload

  defp maybe_put_remote(payload, remote) when is_binary(remote) and remote != "",
    do: Map.put(payload, "remote", remote)

  defp maybe_put_remote(payload, _), do: payload
end

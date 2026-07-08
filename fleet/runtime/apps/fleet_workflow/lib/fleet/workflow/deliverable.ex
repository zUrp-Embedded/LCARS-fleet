defmodule Fleet.Workflow.Deliverable do
  @moduledoc """
  Unified publication of a pod's deliverable — **one** module, two modes selected
  by `spec.deliverable_mode` at the catalogue (entry condition), NOT two modules in disguise. Unification
  filter: "differentiation by catalogue, not by code branch" (same rule as
  `lifetime_scope`).

  Pod↔system boundary. The pod produces CONTENT (a payload of files, OR native git commits);
  the system turns it into a durable deliverable pushed to the forge. The pod is aware of NEITHER the
  branches NOR the forge (forge-blind) — it is the system that chooses the target branch and
  pushes. `git` gives the deliverable's isolation; `bwrap` gives the FS's isolation.

  ## The three stages (fixed order, identical across both modes for 2 and 3)

      1. CONTENT (the only mode-specific branch):
         :payload    → `PayloadGuard.apply_files` (security-validates THEN writes the files)
                       + `Git.commit` (the SYSTEM commits)
         :git_native → the agent has already committed → we just check a commit exists (base != HEAD)
      2. HARDENED GATE — SHARED: `DeliverableGate.verify` (base ancestor, identity, secrets).
         An invalid deliverable is made unrepresentable at push (not caught after the fact).
      3. Bounded PUSH — `Git.push(remote, local_ref:target_branch)` otherwise fail-loud.

  `base_sha` is locked OUTSIDE the pod (captured by the forge-driven rail, pinned at clone by
  `ProjectBootstrap.pin_base_sha`) — the pod cannot falsify it. The gate reads the workspace's `.git`
  read-only and believes NO assertion from the pod.

  Unification guardrail: the ONLY mode divergence is stage 1 (who commits). Stages 2 and 3
  are strictly shared. If one day the `case mode` metastasizes (an `if` that splits 80% of the trunk),
  the unification must be reconsidered.
  """

  require Logger

  alias Fleet.Workflow.{DeliverableGate, Git, PayloadGuard}

  @type mode :: :payload | :git_native

  @type opts :: %{
          required(:mode) => mode(),
          required(:workspace) => Path.t(),
          required(:base_sha) => String.t(),
          required(:allowed_emails) => [String.t()],
          optional(:remote) => String.t(),
          optional(:target_branch) => String.t(),
          optional(:push?) => boolean(),
          optional(:local_ref) => String.t(),
          # Expected role for the `Co-authored-by` trailer; nil/absent → skip.
          optional(:coauthor_role) => String.t() | nil,
          # :payload mode only
          optional(:files) => [map()],
          optional(:identity) => map(),
          optional(:message) => String.t(),
          optional(:add_paths) => [String.t()]
        }

  @type result :: %{commit_sha: String.t(), pushed?: boolean(), mode: mode()}

  # NO more direct git invocation here (2026-07-04): the rev-parses are delegated to
  # `Fleet.Workflow.Git.read_head_sha/1` (bounded, which composes git_safe_config_args itself).

  @common_keys [:mode, :workspace, :base_sha, :allowed_emails]
  @payload_keys [:files, :identity, :message]
  @identity_keys [:author_name, :author_email, :committer_name, :committer_email]

  @doc """
  Publishes the deliverable: CONTENT (mode) → GATE (shared) → PUSH. Returns `{:ok, %{commit_sha,
  pushed?, mode}}` or the FIRST `{:error, reason}` (fail-loud at each stage; no push if the gate
  refuses). `push?` defaults to `true`; `local_ref` defaults to `"HEAD"`.
  """
  @spec publish(opts()) :: {:ok, result()} | {:error, term()}
  def publish(opts) when is_map(opts) do
    with :ok <- validate(opts),
         :ok <- materialize_content(opts),
         {:ok, :verified} <-
           DeliverableGate.verify(
             opts.workspace,
             opts.base_sha,
             opts.allowed_emails,
             Map.get(opts, :coauthor_role)
           ),
         {:ok, sha} <- head_sha(opts.workspace),
         {:ok, pushed?} <- push_deliverable(opts) do
      {:ok, %{commit_sha: sha, pushed?: pushed?, mode: opts.mode}}
    end
  end

  # ============================================================
  # Validation (fail-closed)
  # ============================================================

  defp validate(opts) do
    with :ok <- check_keys(opts, @common_keys),
         :ok <- check_mode(opts.mode),
         :ok <- check_types(opts),
         :ok <- check_mode_keys(opts),
         :ok <- check_push_keys(opts) do
      :ok
    end
  end

  # `@type opts` declares TYPES for the required fields, but `check_keys` only checks PRESENCE — a field
  # present with the WRONG type (a `workspace` that is not a path, an `allowed_emails` that is not a list
  # of strings) would crash the downstream git ops. Validate the types too (R2-07/10, parse-don't-validate
  # at the publish boundary). Reached only after `check_keys` → the keys exist, `opts.<key>` is safe.
  defp check_types(opts) do
    cond do
      not is_binary(opts.workspace) ->
        {:error, {:bad_opt, {:workspace, opts.workspace}}}

      not is_binary(opts.base_sha) ->
        {:error, {:bad_opt, {:base_sha, opts.base_sha}}}

      not (is_list(opts.allowed_emails) and Enum.all?(opts.allowed_emails, &is_binary/1)) ->
        {:error, {:bad_opt, {:allowed_emails, opts.allowed_emails}}}

      true ->
        :ok
    end
  end

  defp check_keys(opts, keys) do
    case Enum.reject(keys, &Map.has_key?(opts, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_opts, missing}}
    end
  end

  defp check_mode(m) when m in [:payload, :git_native], do: :ok
  defp check_mode(m), do: {:error, {:invalid_mode, m}}

  # payload mode: the content keys are required. git_native mode: the content comes from the pod, nothing
  # to supply (the commit's presence is verified at `materialize_content`).
  defp check_mode_keys(%{mode: :payload} = opts) do
    with :ok <- check_keys(opts, @payload_keys),
         :ok <- check_keys(opts.identity, @identity_keys) do
      :ok
    end
  end

  defp check_mode_keys(_opts), do: :ok

  # Push (default true) requires remote + target_branch + a well-formed refspec. If push?
  # is explicitly false (local commit), they are optional.
  defp check_push_keys(opts) do
    if push?(opts) do
      with :ok <- check_keys(opts, [:remote, :target_branch]),
           :ok <- check_ref(opts.target_branch),
           :ok <- check_ref(local_ref(opts)) do
        :ok
      end
    else
      :ok
    end
  end

  # Refspec validation (`<local_ref>:<target_branch>`) delegated to the SINGLE AUTHORITY
  # `Fleet.Workflow.GitRef` (the check-ref-format regex lived here, duplicated with `Git`). We keep the
  # typed error shape specific to this module (which carries the offending `ref`).
  defp check_ref(ref) do
    if Fleet.Workflow.GitRef.valid?(ref), do: :ok, else: {:error, {:invalid_ref, ref}}
  end

  # ============================================================
  # Stage 1 — CONTENT (the only mode divergence)
  # ============================================================

  # Payload placement + security-validation (path-traversal / `.git` / weaponized
  # `.gitattributes` / symlink) delegated to the single authority `Fleet.Workflow.PayloadGuard` (filter
  # extracted 2026-07-05 — the WHY of each closed vector is documented over there).
  defp materialize_content(%{mode: :payload} = opts) do
    with :ok <- PayloadGuard.apply_files(opts.workspace, opts.files),
         {:ok, _sha} <- Git.commit(commit_opts(opts)) do
      :ok
    end
  end

  # git_native: the agent committed inside the pod. We create NOTHING — we just check a deliverable
  # exists (HEAD has advanced past base). Empty range = the brief produced no commit → fail-loud
  # (the gate itself passes on an empty range by vacuity; the commit's presence is a mode-side concern).
  # The "HEAD != base but history rewritten" case passes here (advanced) and is caught by the gate
  # (`base_not_ancestor`) — no double check here.
  defp materialize_content(%{mode: :git_native} = opts) do
    if head_advanced?(opts.workspace, opts.base_sha),
      do: :ok,
      else: {:error, :no_deliverable_commit}
  end

  # HEAD read delegated to the BOUNDED authority Fleet.Workflow.Git.read_head_sha/1 (2026-07-04:
  # this site was a RAW System.cmd with no deadline — a hung rev-parse blocked publication).
  # Read failure → false = "no commit detected" → the caller returns
  # {:error, :no_deliverable_commit} (EXPLICIT failure, not a silence).
  defp head_advanced?(workspace, base_sha) do
    case Fleet.Workflow.Git.read_head_sha(workspace) do
      {:ok, sha} -> sha != base_sha
      {:error, _} -> false
    end
  end

  defp commit_opts(opts) do
    opts.identity
    |> Map.take(@identity_keys)
    |> Map.merge(%{
      workspace: opts.workspace,
      message: opts.message,
      add_paths: Map.get(opts, :add_paths, ["."])
    })
  end

  # ============================================================
  # Stage 3 — PUSH (shared)
  # ============================================================

  defp push_deliverable(opts) do
    if push?(opts) do
      refspec = "#{local_ref(opts)}:#{opts.target_branch}"
      Git.push(opts.workspace, opts.remote, refspec)
    else
      {:ok, false}
    end
  end

  defp push?(opts), do: Map.get(opts, :push?, true)
  defp local_ref(opts), do: Map.get(opts, :local_ref, "HEAD")

  # 2026-07-04: delegated to the bounded authority (same error shape {:rev_parse_failed, rc, err},
  # enriched with {:rev_parse_timeout|:rev_parse_exit} that the raw System.cmd could not produce).
  defp head_sha(workspace), do: Fleet.Workflow.Git.read_head_sha(workspace)
end

defmodule Fleet.Spawner.Pod.Assets do
  @moduledoc """
  READ + PROVISION of a pod's vendor/priv ASSETS — island extracted from `Fleet.Spawner.Pod.Scaffold`.

  Everything the `:projecting` state READS from the fleet apps' `priv/` (role-aware SP draft,
  worker protocole-user, `watch.sh`) or MANUFACTURES as static content (the REPL's `settings.json`),
  plus the cap-profile skills filter. Each step returns `{:ok, content}`/`:ok` or an
  `{:error, reason}` TAGGED per asset (the tag identifies the failing step in the
  `transition_failed` of the `:projecting` state) — the `with` of `:projecting` propagates.

  This module knows NEITHER the brief (TaskQueue channel — `Pod.Brief`), NOR the project workspace
  (git clone — `Pod.Scaffold`): assets only. No state, no Port, no timer. Depends on
  `Pod.Fs` (non-bang write of `watch.sh`), `Fleet.SPBuilder` (skills filter), `Fleet.CapProfile`
  (single source of the `name`), `Fleet.Slug` (validation of the role interpolated into a path) and
  `Application` (config + `priv/` assets). No dependency on `Fleet.Spawner.Pod` (no cycle).

  ## Contract (called by `Pod`, `:projecting` state)

  - `pod_settings_json/0`, `read_agent_draft/1`, `read_protocole_user/0`, `maybe_path/1`,
    `maybe_filter_skills/2`, `provision_monitor_watch/1` — steps of the `:projecting` `with`.

  **Last revised**: 2026-07-18
  """

  alias Fleet.Spawner.Pod.Fs

  @doc """
  Minimal `settings.json` for the pod's claude REPL (written to `.lcars/` by the `:projecting` state).

  `skipDangerousModePermissionPrompt: true` — pre-accepts the interactive warning claude shows
  on first boot under `--dangerously-skip-permissions`; without this key, the pod's tmux session
  freezes on "By proceeding, you accept..." (option 1/2 + Enter).
  `hasCompletedOnboarding: true` also skips onboarding (the legacy `.claude.json` — the
  host user's global config — is not meant to be touched here).
  """
  @spec pod_settings_json() :: String.t()
  def pod_settings_json do
    Jason.encode!(
      %{
        "hasCompletedOnboarding" => true,
        "hasAcknowledgedCostThreshold" => true,
        "skipDangerousModePermissionPrompt" => true
      },
      pretty: true
    )
  end

  @doc """
  Role-aware SP draft: a role's draft is `agent-<role>-base.md`, resolved by `metadata.name`. Pod drafts are
  composed by blocks (`Fleet.SPBuilder.Blocks` + `mix lcars.sp.gen`).

  **NO-FALLBACK** (cf. memory no-sp-no-pod-no-fleet): a role without its dedicated draft → `{:error,
  {:agent_draft_missing, …}}` → hard spawn death (`:projecting` state). No more silent degradation to a
  generic draft — a role without an SP is a rejected half-role. `role` is interpolated into a path →
  validated via the slug smart-constructor (a malformed `role` → `{:error, {:agent_draft_invalid_role, role}}`).
  """
  @spec read_agent_draft(Fleet.CapProfile.t()) ::
          {:ok, String.t()}
          | {:error,
             {:agent_draft_missing, Path.t(), File.posix()}
             | {:agent_draft_invalid_role, String.t()}}
  def read_agent_draft(%Fleet.CapProfile{} = cap) do
    role = Fleet.CapProfile.name(cap)

    # NO-FALLBACK (cf. memory no-sp-no-pod-no-fleet): EACH role MUST have its dedicated SP
    # `agent-<role>-base.md`. Missing → `{:error, {:agent_draft_missing, …}}` → `:projecting` state failure
    # → HARD spawn death. No SP → no pod → no fleet. No silent degradation to a generic draft (a role without
    # an SP = a dirty half-role → the system refuses). A vanilla agent = `claude` launched by hand outside the
    # fleet, never through the forge. `role` is interpolated into a path → a malformed slug is a broken
    # cap-profile (fail-loud), not a fallback.
    if Fleet.Slug.valid?(role) do
      read_tagged(
        Application.app_dir(:lcars_fleet, "priv/sp_builder/sp_drafts/agent-#{role}-base.md"),
        :agent_draft_missing
      )
    else
      {:error, {:agent_draft_invalid_role, role}}
    end
  end

  @doc """
  The pod's `protocole-user.md` (custom keywords `yop`/`SeeU`). Default =
  `priv/sp_builder/sp_drafts/protocole-user-worker.md` shipped in the bundled priv: the WORKER version
  (`yop` = trigger the issue-driven workflow, `SeeU` = no-op). Override via config
  `:fleet_spawner, :protocole_user_path` (custom user instance).

  TRAP: pointing at a HUMAN instance's protocole-user (which redefines `yop` as
  "session resume, read handoff", or neutralizes it) → the pod's claude REPL does NOT trigger
  the worker workflow.
  """
  @spec read_protocole_user() ::
          {:ok, String.t()} | {:error, {atom(), Path.t(), File.posix()}}
  def read_protocole_user do
    case Application.get_env(:fleet_spawner, :protocole_user_path) do
      nil ->
        :lcars_fleet
        |> Application.app_dir("priv/sp_builder/sp_drafts/protocole-user-worker.md")
        |> read_tagged(:protocole_user_worker_missing)

      path when is_binary(path) ->
        read_tagged(path, :protocole_user_missing)
    end
  end

  # TAGGED read of a provisioned asset (SP draft, protocole-user): `{:ok, content}` or
  # `{:error, {<tag>, path, reason}}` — the tag stays SPECIFIC to each asset (it identifies the failing
  # step in the `transition_failed` of the `:projecting` state), only the read→tuple mechanics are
  # shared.
  defp read_tagged(path, error_tag) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {error_tag, path, reason}}
    end
  end

  @doc """
  `path` if it exists on disk, otherwise `nil`. Optional-asset resolution (e.g. the
  `CLAUDE.md.repo-source` passed to `SPBuilder.compose_claude_md` by the `:projecting` state).
  """
  @spec maybe_path(Path.t()) :: Path.t() | nil
  def maybe_path(path) do
    if File.exists?(path), do: path, else: nil
  end

  @doc """
  Filters the cap-profile's skills under `root` (delegated to `Fleet.SPBuilder.filter_skills/2`).
  No `skills_root` configured (`nil`) → `{:ok, []}` (nothing to filter).
  """
  @spec maybe_filter_skills(Fleet.CapProfile.t(), Path.t() | nil) ::
          {:ok, [Path.t()]} | {:error, term()}
  def maybe_filter_skills(_cap_profile, nil), do: {:ok, []}

  def maybe_filter_skills(cap_profile, root) do
    Fleet.SPBuilder.filter_skills(cap_profile, root)
  end

  @doc """
  Provisions the in-pod monitor (`watch.sh`) into the pod_dir (= bwrap HOME). The agent arms it via
  the native `Monitor` tool (cf. the role's SP, `core/runtime-contract` block) → wake-by-flag
  (`turn.flag` touched by the fleet), zero CONTENT send-keys. The asset lives in the bundled
  `priv/spawner/` (resolved via `app_dir`, like the SP draft). The `File.chmod` return is discarded
  (`_ =`): the exec bit carries nothing here — the agent runs `bash ~/watch.sh`, never `./watch.sh`;
  the op whose error matters is the `safe_write`, which does propagate.
  """
  @spec provision_monitor_watch(map()) :: :ok | {:error, term()}
  def provision_monitor_watch(state) do
    src = Application.app_dir(:lcars_fleet, "priv/spawner/watch.sh")
    dst = Path.join(state.pod_dir, "watch.sh")

    case File.read(src) do
      {:ok, content} ->
        with :ok <- Fs.safe_write(dst, content) do
          _ = File.chmod(dst, 0o755)
          :ok
        end

      {:error, reason} ->
        {:error, {:watch_asset_unreadable, reason}}
    end
  end
end

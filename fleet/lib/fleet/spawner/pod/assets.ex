defmodule Fleet.Spawner.Pod.Assets do
  @moduledoc """
  READ + PROVISION of a pod's vendor/priv ASSETS — island extracted from `Fleet.Spawner.Pod.Scaffold`.

  Everything the `:projecting` state READS from the fleet apps' `priv/` (role-aware SP draft,
  the protocole-user selected by the profile's `interlocutor`, `watch.sh`) or MANUFACTURES as
  static content (the REPL's `settings.json`),
  plus the cap-profile skills filter. Each step returns `{:ok, content}`/`:ok` or an
  `{:error, reason}` TAGGED per asset (the tag identifies the failing step in the
  `transition_failed` of the `:projecting` state) — the `with` of `:projecting` propagates.

  This module knows NEITHER the brief (TaskQueue channel — `Pod.Brief`), NOR the project workspace
  (git clone — `Pod.Scaffold`): assets only. No state, no Port, no timer. Depends on
  `Pod.Fs` (non-bang write of `watch.sh`), `Fleet.SPBuilder` (skills filter), `Fleet.CapProfile`
  (single source of the `name`), `Fleet.Slug` (validation of the role interpolated into a path) and
  `Application` (config + `priv/` assets). No dependency on `Fleet.Spawner.Pod` (no cycle).

  ## Contract (called by `Pod`, `:projecting` state)

  - `pod_settings_json/0`, `read_agent_draft/1`, `read_protocole_user/1`, `maybe_path/1`,
    `maybe_filter_skills/2`, `provision_monitor_watch/1` — steps of the `:projecting` `with`.
  """

  alias Fleet.CapProfile
  alias Fleet.SPBuilder
  alias Fleet.Spawner.Pod.Fs

  @doc """
  The pod REPL's `settings.json` — COMPLETE, single-owner (written to `.lcars/` by the
  `:projecting` state; BL-6-07: the launcher no longer composes or merges anything, it only
  passes the file through `--settings`). Before this, TWO tiers wrote the same file with TWO
  policies: this module put `skipDangerousModePermissionPrompt: true` unconditionally
  (pre-kill-yolo), while `claude_launch.sh` jq-merged its own keys and reserved the skip-dialog
  to bypass — and the unconditional side WON the merge, shipping every restricted pod a
  pre-accepted danger dialog. One owner now, and the kill-yolo policy is the one that holds:

  `skipDangerousModePermissionPrompt: true` ONLY under `permission_mode == "bypassPermissions"`
  (`LaunchSpec.permission_mode/1`, the same authority that exports `LCARS_PERMISSION_MODE`) —
  it pre-accepts the interactive "By proceeding, you accept..." dialog that hangs a headless
  pod; a default/restricted pod gets NO pre-acceptance.
  `hasCompletedOnboarding: true` skips onboarding (the legacy `.claude.json` — the host user's
  global config — is not meant to be touched here).
  `autoMemoryEnabled: false` (F-POD-AUTOMEM, moved from the launcher): the pod's claude
  auto-memory is siloed, useless to the fleet, and doctrine pollution (BUG-3) — off for every
  permission mode.
  ⚠ PAS DE `extensions.marketplace.autoInstall: false` ICI : IL N'Y FAIT RIEN. The problem is real
  — left on, every spawn clones the vendor's plugin marketplace to install zero plugin, and a pod
  running inside a projected world must not fetch code from the internet at boot — but this is not
  the lever. Measured on CLI 2.1.221, both directions: two pods carrying this key installed 7.2 MB
  of plugins anyway; a pod whose `.claude.json` carried `officialMarketplaceAutoInstalled` had no
  `plugins/` at all. The vendor gates this on ITS OWN config keys, and `--settings` is documented
  as ADDITIONAL settings, not an overriding tier. The effective lever lives where it works, in
  `claude_launch.sh`'s `.claude.json`, with the measurement written next to it. A setting that declares an intention it cannot enforce is worse
  than no setting: it tells every reader the matter is handled.
  """
  @spec pod_settings_json(CapProfile.t()) :: String.t()
  def pod_settings_json(%CapProfile{} = cap_profile) do
    base = %{
      "hasCompletedOnboarding" => true,
      "hasAcknowledgedCostThreshold" => true,
      "autoMemoryEnabled" => false,
      # TUI plein ecran (release vendor recente). C'est une CLE DE SETTINGS, pas un flag : les 62
      # options de la CLI 2.1.221 n'en portent aucune equivalente, donc `--settings` est la seule
      # voie vers un pod. Verifie a la main par l'user dans un vrai terminal ET sous tmux, ce qui
      # est le cas d'un pod (PTY de tmux, ADR-G).
      "tui" => "fullscreen"
    }

    settings =
      if Fleet.Spawner.Pod.LaunchSpec.permission_mode(cap_profile) == "bypassPermissions",
        do: Map.put(base, "skipDangerousModePermissionPrompt", true),
        else: base

    Jason.encode!(settings, pretty: true)
  end

  @doc """
  Reads the profile's SP: `agent-<role>-base.md`, or the draft of the role its `spec.systemPrompt`
  names.

  Missing image or disk content and invalid role slugs return tagged errors; there
  is no generic fallback.

  ## `spec.systemPrompt` — DECLARED reuse, and the only alternative

  A cap-profile grants PERMISSIONS; its SP decides BEHAVIOUR. So a role with no prompt of its own
  behaves like whoever's prompt it ends up with, and its name lies — which is why the generic
  `agent-worker-base.md` fallback was removed (no SP, no pod). The single legitimate case is
  RENAMING: a catalogue that renames a role into its own language would otherwise copy two hundred
  lines that then drift, the substrate defect one floor up.

  It names a ROLE, not a path. The reuse is then stated in the catalogue's own vocabulary, there is
  nothing to sanitise or escape, and the key already exists in the frozen image. The distinction
  that makes it safe is DECLARED versus SILENT: a role inheriting a prompt by accident stays
  refused; one that says so in its yaml has assumed it.
  """
  @spec read_agent_draft(CapProfile.t()) ::
          {:ok, String.t()}
          | {:error,
             {:agent_draft_missing, Path.t(), File.posix()}
             | {:agent_draft_invalid_role, String.t()}}
  def read_agent_draft(%CapProfile{spec: spec} = cap) do
    role =
      case spec do
        %{"systemPrompt" => borrowed} when is_binary(borrowed) -> borrowed
        _ -> CapProfile.name(cap)
      end

    if Fleet.Slug.valid?(role) do
      case SPBuilder.image_draft(role, cap.catalogue_root) do
        {:ok, content} ->
          {:ok, content}

        :not_found ->
          {:error,
           {:agent_draft_missing, "agent-#{role}-base.md (absent from the published SP image)",
            :enoent}}

        :unpublished ->
          read_tagged(
            SPBuilder.sp_draft_path(role, cap.catalogue_root),
            :agent_draft_missing
          )
      end
    else
      {:error, {:agent_draft_invalid_role, role}}
    end
  end

  @doc """
  Selects `protocole-user.md` from the profile's `interlocutor`.

  `fleet` receives the machine protocol, `human` the conversation protocol, and
  `both` receives machine then human. The configured protocol path overrides only
  the machine half.
  """
  @spec read_protocole_user(CapProfile.t()) ::
          {:ok, String.t()} | {:error, {atom(), Path.t(), File.posix()}}
  def read_protocole_user(%CapProfile{} = cap) do
    # La racine vient du PROFIL : le protocole qu'un pod recoit appartient au catalogue qui declare
    # son role. Sans ca, un role du second catalogue recevait le protocole du premier — un contrat de
    # conversation ecrit pour d'autres gens.
    root = cap.catalogue_root

    case CapProfile.interlocutor(cap) do
      "human" ->
        read_human_protocol(root)

      "both" ->
        with {:ok, machine} <- read_worker_protocol(root),
             {:ok, human} <- read_human_protocol(root) do
          {:ok, machine <> "\n---\n\n" <> human}
        end

      _ ->
        read_worker_protocol(root)
    end
  end

  defp read_worker_protocol(root) do
    case SPBuilder.image_worker_protocol(root) do
      {:ok, content} -> {:ok, content}
      :unpublished -> read_worker_protocol_from_disk(root)
    end
  end

  defp read_human_protocol(root) do
    case SPBuilder.image_human_protocol(root) do
      {:ok, content} ->
        {:ok, content}

      :unpublished ->
        # The SCOPE, not the search path — the pod's own catalogue plus the system one, the same
        # pair its image is frozen from. The scope is a pair and never the business root alone: the
        # human protocol follows the roles that need it, and the only `interlocutor: both` roles
        # live in the system catalogue — reading one root demanded this file from catalogues whose
        # every role is `interlocutor: fleet` (W-13). And never the FLATTENED path either
        # (`find(:sp_drafts, …)` walked every installed catalogue): a `mobile` pod would have read
        # `web-demo`'s protocol on disk while its image raised — a conversation contract written
        # for other people, served on exactly the regime hermetic tests measure.
        protocol_from_disk(root, "protocole-user-human.md", :protocole_user_human_missing)
    end
  end

  defp read_worker_protocol_from_disk(root) do
    case Application.get_env(:lcars_fleet, :spawner_protocole_user_path) do
      nil ->
        protocol_from_disk(root, "protocole-user-worker.md", :protocole_user_worker_missing)

      path when is_binary(path) ->
        read_tagged(path, :protocole_user_missing)
    end
  end

  # `root` is nil for a profile loaded without a named catalogue: the BUNDLED one, because that is
  # what the image regime answers for the same caller. The not-found error names a path in the
  # scope's OWN tree, never a foreign one — send the author to the tree they own.
  #
  # The rule is stated here rather than delegated to another function's name: a rule that outlives
  # the function it is attached to should not go looking for it.
  defp protocol_from_disk(root, name, error_tag) do
    scope_root = root || Fleet.Catalogue.root()
    scope = Fleet.Catalogue.tree_scope(scope_root, :sp_drafts)

    path =
      Fleet.Catalogue.find_in(scope, name) ||
        Path.join([scope_root, Fleet.Catalogue.rel(:sp_drafts), name])

    read_tagged(path, error_tag)
  end

  defp read_tagged(path, error_tag) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {error_tag, path, reason}}
    end
  end

  @doc """
  Returns an optional asset path when it exists.
  """
  @spec maybe_path(Path.t()) :: Path.t() | nil
  def maybe_path(path) do
    if File.exists?(path), do: path, else: nil
  end

  @doc """
  Filters the profile's skills under `root`; a nil root yields an empty selection.
  """
  @spec maybe_filter_skills(CapProfile.t(), Path.t() | nil) ::
          {:ok, [Path.t()]} | {:error, term()}
  def maybe_filter_skills(_cap_profile, nil), do: {:ok, []}

  def maybe_filter_skills(cap_profile, root) do
    SPBuilder.filter_skills(cap_profile, root)
  end

  @doc """
  Copies the bundled `watch.sh` monitor into the pod directory.

  Read and write failures propagate; chmod remains best-effort because the script is
  invoked through `bash`.
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

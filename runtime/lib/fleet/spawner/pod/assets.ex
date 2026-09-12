defmodule Fleet.Spawner.Pod.Assets do
  @moduledoc """
  Reads and provisions pod assets during `:projecting`: role prompts, user protocols,
  REPL settings, skills and the monitor script. Asset failures return tagged errors
  for the pod’s projection failure path. Briefs belong to `Pod.Brief`; workspace
  cloning belongs to `Pod.Scaffold`.
  """

  alias Fleet.CapProfile
  alias Fleet.Spawner.Pod.Fs
  alias Fleet.SPBuilder

  @doc """
  Builds the complete `.lcars/settings.json`; the vendor launcher passes it to `--settings`.
  Only `bypassPermissions` pre-accepts the dangerous-mode dialog, avoiding a headless
  prompt while keeping restricted modes unacknowledged. Onboarding is skipped and
  auto-memory is disabled because it is private to the pod rather than shared fleet state.

  Marketplace installation is controlled in the launcher’s `.claude.json` projection.
  The `extensions.marketplace.autoInstall` settings key was ineffective on CLI 2.1.221;
  keep that control at the vendor config layer.
  """
  @spec pod_settings_json(CapProfile.t()) :: String.t()
  def pod_settings_json(%CapProfile{} = cap_profile) do
    base = %{
      "hasCompletedOnboarding" => true,
      "hasAcknowledgedCostThreshold" => true,
      "autoMemoryEnabled" => false,
      # Fullscreen TUI is selected through settings; the tested CLI 2.1.221 has no equivalent flag.
      "tui" => "fullscreen"
    }

    settings =
      if Fleet.Spawner.Pod.LaunchSpec.permission_mode(cap_profile) == "bypassPermissions",
        do: Map.put(base, "skipDangerousModePermissionPrompt", true),
        else: base

    Jason.encode!(settings, pretty: true)
  end

  @doc """
  Reads `agent-<role>-base.md` from the published image, or disk while unpublished.
  A missing prompt returns a tagged error; there is no generic worker fallback.
  `spec.systemPrompt` explicitly borrows another role’s prompt, allowing role renames
  without copying it. The value names a role, not a path, and must pass slug validation.
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
  `both` receives machine then human. When reading from disk, the configured
  protocol path overrides only the machine half; a published image takes precedence.
  """
  @spec read_protocole_user(CapProfile.t()) ::
          {:ok, String.t()} | {:error, {atom(), Path.t(), File.posix()}}
  def read_protocole_user(%CapProfile{} = cap) do
    # Use the declaring catalogue’s protocol, not another installed catalogue’s.
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
        # Limit fallback lookup to this catalogue plus the system catalogue, matching the image.
        # System roles may need the human protocol even when all business roles use fleet.
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

  # A nil root uses the bundled catalogue, matching image lookup. Missing-file errors
  # name a path in that catalogue so the author can repair the correct tree.
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

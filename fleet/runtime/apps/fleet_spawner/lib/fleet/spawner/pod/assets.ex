defmodule Fleet.Spawner.Pod.Assets do
  @moduledoc """
  LECTURE + PROVISION des ASSETS vendor/priv d'un pod — île extraite de `Fleet.Spawner.Pod.Scaffold`.

  Tout ce que l'état `:projecting` LIT depuis les `priv/` des apps fleet (draft SP role-aware,
  protocole-user worker, `watch.sh`) ou FABRIQUE comme contenu statique (`settings.json` du REPL),
  plus le filtre des skills du cap-profile. Chaque étape rend `{:ok, content}`/`:ok` ou un
  `{:error, reason}` TAGGÉ par asset (le tag identifie l'étape en échec dans le
  `transition_failed` de l'état `:projecting`) — le `with` de `:projecting` propage.

  Ce module ne connaît NI le brief (canal TaskQueue — `Pod.Brief`), NI le workspace projet
  (clone git — `Pod.Scaffold`) : que des assets. Aucun state, aucun Port, aucun timer. Dépend de
  `Pod.Fs` (écriture non-bang de `watch.sh`), `Fleet.SPBuilder` (filtre skills), `Fleet.CapProfile`
  (source unique du `name`), `Fleet.Slug` (validation du rôle interpolé dans un path) et
  `Application` (config + assets `priv/`). Aucune dépendance vers `Fleet.Spawner.Pod` (pas de cycle).

  ## Contrat (appelé par `Pod`, état `:projecting`)

  - `pod_settings_json/0`, `read_agent_draft/1`, `read_protocole_user/0`, `maybe_path/1`,
    `maybe_filter_skills/2`, `provision_monitor_watch/1` — étapes du `with` de `:projecting`.
  """

  alias Fleet.Spawner.Pod.Fs

  @doc """
  `settings.json` minimal pour le claude REPL du pod (écrit en `.lcars/` par l'état `:projecting`).

  `skipDangerousModePermissionPrompt: true` — pré-accepte le warning interactif que claude affiche
  au premier boot sous `--dangerously-skip-permissions` ; sans cette clé, la session tmux du pod se
  fige sur « By proceeding, you accept... » (option 1/2 + Enter). Pattern repris du consultant
  LCARS v1. `hasCompletedOnboarding: true` skip aussi l'onboarding (le `.claude.json` legacy — la
  config globale du user host — n'a pas vocation à être touché ici).
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
             {:agent_draft_missing, Path.t(), File.posix()} | {:agent_draft_invalid_role, String.t()}}
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
        Application.app_dir(:fleet_sp_builder, "priv/sp_drafts/agent-#{role}-base.md"),
        :agent_draft_missing
      )
    else
      {:error, {:agent_draft_invalid_role, role}}
    end
  end

  @doc """
  `protocole-user.md` du pod (mots-clés personnalisés `yop`/`SeeU`). Défaut =
  `priv/sp_drafts/protocole-user-worker.md` shippé avec `fleet_sp_builder` : version WORKER
  (`yop` = trigger workflow issue-driven, `SeeU` = no-op). Override par config
  `:fleet_spawner, :protocole_user_path` (instance utilisateur custom).

  PIÈGE évité : pointer sur le protocole-user d'une instance HUMAINE (qui redéfinit `yop` en
  « reprise de session lire handoff », ou le neutralise) → le claude REPL du pod ne déclenche PAS
  le workflow worker. (Réellement rencontré sur une instance dont le protocole-user redéfinissait `yop`.)
  """
  @spec read_protocole_user() ::
          {:ok, String.t()} | {:error, {atom(), Path.t(), File.posix()}}
  def read_protocole_user do
    case Application.get_env(:fleet_spawner, :protocole_user_path) do
      nil ->
        :fleet_sp_builder
        |> Application.app_dir("priv/sp_drafts/protocole-user-worker.md")
        |> read_tagged(:protocole_user_worker_missing)

      path when is_binary(path) ->
        read_tagged(path, :protocole_user_missing)
    end
  end

  # Lecture TAGGÉE d'un asset provisionné (draft SP, protocole-user) : `{:ok, content}` ou
  # `{:error, {<tag>, path, reason}}` — le tag reste PROPRE à chaque asset (il identifie l'étape en
  # échec dans le `transition_failed` de l'état `:projecting`), seule la mécanique read→tuple est
  # partagée.
  defp read_tagged(path, error_tag) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {error_tag, path, reason}}
    end
  end

  @doc """
  `path` s'il existe sur disque, sinon `nil`. Résolution d'asset optionnel (ex. le
  `CLAUDE.md.repo-source` passé à `SPBuilder.compose_claude_md` par l'état `:projecting`).
  """
  @spec maybe_path(Path.t()) :: Path.t() | nil
  def maybe_path(path) do
    if File.exists?(path), do: path, else: nil
  end

  @doc """
  Filtre les skills du cap-profile sous `root` (délégué à `Fleet.SPBuilder.filter_skills/2`).
  Pas de `skills_root` configurée (`nil`) → `{:ok, []}` (aucun filtrage à faire).
  """
  @spec maybe_filter_skills(Fleet.CapProfile.t(), Path.t() | nil) ::
          {:ok, [Path.t()]} | {:error, term()}
  def maybe_filter_skills(_cap_profile, nil), do: {:ok, []}

  def maybe_filter_skills(cap_profile, root) do
    Fleet.SPBuilder.filter_skills(cap_profile, root)
  end

  @doc """
  Provisionne le monitor in-pod (`watch.sh`) dans le pod_dir (= HOME bwrap). L'agent l'arme via
  l'outil natif `Monitor` (cf. SP du rôle, bloc `core/runtime-contract`) → réveil-par-flag (`turn.flag` touché par
  la fleet), zéro send-keys de CONTENU. L'asset vit en `priv/` de `fleet_spawner` (résolu
  `app_dir`, comme le SP draft). chmod best-effort : l'agent lance `bash ~/watch.sh`, le bit exec
  n'est pas requis.
  """
  @spec provision_monitor_watch(map()) :: :ok | {:error, term()}
  def provision_monitor_watch(state) do
    src = Application.app_dir(:fleet_spawner, "priv/watch.sh")
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

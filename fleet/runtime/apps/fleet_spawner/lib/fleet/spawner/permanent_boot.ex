defmodule Fleet.Spawner.PermanentBoot do
  @moduledoc """
  Boot des pods permanents Type 1 fleet-level **au démarrage du runtime fleet_v2
  lancé par l'humain** (`bin/fleet_v2 start` démarre la BEAM sous l'UID de l'humain
  puis boote le pod architect permanent — modèle humain-lance, plus de service
  système, systemd retiré). Extension `fleet_spawner` (PAS refactor).


  ## Garde anti-violation CRITIQUE

  `boot_at_start?/1` n'autorise un boot fleet_spawner que si
  `boot_at_start: true` **ET** `lifetime_scope: forever` **ET**
  `host_native != true`. Le 3e terme est la **garde anti-violation** :
  `starfleet` (host_native: true, dérogation canon) ne DOIT
  JAMAIS être spawné via fleet_spawner bwrap
  (il boote à part, host-native hors de fleet_spawner — `host_launch.sh`,
  containment: none). Garde défensive même si un profil host_native portait
  `boot_at_start: true` par erreur.

  ## Clés string, pas atom

  Le `%Fleet.CapProfile{}` réel a `spec :: map()` à **clés
  string** (cf. `cap_profile.ex`, `spec: Map.get(raw, "spec", %{})`).
  Coder des atom-keys (`get_in(cp, [:spec, :invocation, ...])`) → `nil` →
  0 pod booté silencieusement. D'où l'accès string-keyed ici.

  """

  require Logger

  @doc """
  Le cap-profile doit-il booter au démarrage fleet (Type 1) ?

  `true` ssi `spec.invocation.boot_at_start == true` ET
  `spec.invocation.lifetime_scope == "forever"` ET
  **`spec.invocation.host_native != true`** (garde anti-violation).
  """
  @spec boot_at_start?(Fleet.CapProfile.t() | map()) :: boolean()
  def boot_at_start?(%Fleet.CapProfile{spec: spec}), do: boot_at_start?(spec)

  def boot_at_start?(%{} = spec) do
    inv = Map.get(spec, "invocation", %{})

    Map.get(inv, "boot_at_start") == true and
      Map.get(inv, "lifetime_scope") == "forever" and
      Map.get(inv, "host_native") != true
  end

  def boot_at_start?(_), do: false

  @doc """
  Filtre une liste de cap-profiles → ceux éligibles au boot permanent
  Type 1 (garde `boot_at_start?/1` appliquée, host_native exclu).
  """
  @spec select_permanent([Fleet.CapProfile.t()]) :: [Fleet.CapProfile.t()]
  def select_permanent(cap_profiles) when is_list(cap_profiles) do
    Enum.filter(cap_profiles, &boot_at_start?/1)
  end

  @doc """
  Boot des pods permanents Type 1.
  Invoqué post-readiness par l'**autorité unique**
  `Fleet.Starfleet.BootOrchestrator` (le hook `Fleet.Spawner.Application`
  qui l'invoquait aussi a été retiré pour éviter le double-boot).

  Énumère les rôles du répertoire cap-profiles → délègue le chargement+
  validation au loader canonique `Fleet.CapProfile.load/1` (DRY — pas de
  re-parse YAML) → garde `select_permanent/1` (host_native exclu) →
  `spawn_pod/3`
  (signature réelle `(%CapProfile{}, issue_id, opts)`).

  ## Échec de LOAD vs échec de SPAWN

  **Un cap-profile qui ne CHARGE pas** (absent / YAML corrompu / schema invalide) = artefact de
  deploy cassé → **fail-loud** : `boot_permanent_pods/1` rend `{:error, {:cap_profile_load_failed,
  role, reason}}` (BootOrchestrator → `fleet.boot_failed`, pas `boot_complete` vert amputé). Sans
  le fail-loud, ces échecs seraient droppés en silence — c'est le « truc blessé qu'on garde en
  vie » que la doctrine rejette.

  **Un échec de SPAWN** (bwrap/launch KO) n'arrête PAS les autres (chacun tente), mais n'est PLUS
  filtré en silence (G9) : il est rendu en `{:error, {role, reason}}` dans la liste des résultats →
  le BootOrchestrator émet `fleet.boot_partial` (le permanent manquant est NOMMÉ, pas de
  `boot_complete` vert amputé). Jupiter-grade : personne ne court derrière avec une checklist —
  le boot dit la vérité lui-même, et le `PermanentWarden` (G5) re-tente sur `pod.failed`.

  ## Écrivain unique state.json

  PermanentBoot **spawne** mais **n'écrit pas** `state.json` — l'écriture est
  déléguée au `gen_statem` `Fleet.Spawner.Pod` (via `Pod.StateFs.write_state_fs/1`). Un seul
  écrivain : pas de seam `:state_writer` parallèle.

  ## Seams (découplage de l'IO pour les tests)
    * `:cap_profiles_dir` — répertoire scanné (défaut config
      `:fleet_spawner, :cap_profiles_dir`)
    * `:loader` — `(role :: String.t()) -> {:ok, cp} | {:error, term}`
      (défaut `&Fleet.CapProfile.load/1`)
    * `:spawner` — `(cp, issue_id, opts) -> {:ok, pid} | {:error, term}`
      (défaut `&Fleet.Spawner.spawn_pod/3`)
  """
  # G9 : rend la LISTE DES RÉSULTATS `[{:ok, pod_id} | {:error, {role, reason}}]` — un spawn raté
  # n'est PLUS filtré (l'ancien `reject(&is_nil/1)` rendait `{:ok, liste_partielle}` → boot MENTEUR).
  # `safe_boot` (BootOrchestrator) classe nativement la liste : tout-ok → boot_complete, mixte →
  # boot_partial. Erreur GLOBALE (deploy cassé) → `{:error, reason}` inchangé (→ boot_failed).
  @spec boot_permanent_pods(keyword()) ::
          [{:ok, String.t()} | {:error, {String.t(), term()}}] | {:error, term()}
  def boot_permanent_pods(opts \\ []) when is_list(opts) do
    dir = Keyword.get(opts, :cap_profiles_dir) || cap_profiles_dir()
    loader = Keyword.get(opts, :loader, &Fleet.CapProfile.load/1)
    spawner = Keyword.get(opts, :spawner, &Fleet.Spawner.spawn_pod/3)

    with {:ok, roles} <- list_roles(dir),
         {:ok, cps} <- load_all(roles, loader) do
      cps
      |> select_permanent()
      |> Enum.map(&spawn_one(&1, spawner))
    else
      # Un load raté = deploy cassé → on propage tel quel (fail-loud). Distinct du dir
      # illisible (`list_roles`), classé `:cap_profiles_dir_unreadable`.
      {:error, {:cap_profile_load_failed, _role, _reason}} = err ->
        err

      {:error, reason} ->
        {:error, {:cap_profiles_dir_unreadable, reason}}
    end
  end

  @doc """
  Re-spawn UN pod permanent mort (G5, cattle rebuildable) — appelé par `Fleet.Spawner.PermanentWarden`
  sur `pod.failed` d'un pod `permanent-<role>`. Réutilise EXACTEMENT le chemin de boot (`spawn_one`) :
  pod_id déterministe idempotent (`{:already_started}` = no-op si le pod est revenu entre-temps) +
  boot-from-base si une base existe (UUID stable + contexte FRAIS restauré depuis la base — le respawn
  ne reprend JAMAIS la session accumulée du pod mort, cohérent avec la recovery fresh-reroll).

  Garde-fou : le cap-profile chargé doit être un PERMANENT (`boot_at_start?`) — refuse fail-loud sinon
  (un rôle non-permanent n'a rien à faire ici, même si un pod_id `permanent-*` forgé le demandait).

  Returns `{:ok, pod_id}` | `{:error, {role, reason}}`.
  """
  @spec respawn(String.t(), keyword()) :: {:ok, String.t()} | {:error, {String.t(), term()}}
  def respawn(role, opts \\ []) when is_binary(role) and is_list(opts) do
    loader = Keyword.get(opts, :loader, &Fleet.CapProfile.load/1)
    spawner = Keyword.get(opts, :spawner, &Fleet.Spawner.spawn_pod/3)

    case loader.(role) do
      {:ok, %Fleet.CapProfile{} = cp} ->
        if boot_at_start?(cp.spec),
          do: spawn_one(cp, spawner),
          else: {:error, {role, :not_a_permanent}}

      {:error, reason} ->
        {:error, {role, {:cap_profile_load_failed, reason}}}
    end
  end

  @doc """
  Le boot des pods permanents est-il activé ? Config `:fleet_spawner,
  :boot_permanent_at_start` — **défaut `true`** (« default true en prod, false en
  test » ; `false` désactive). Pur,
  testable (gate découplé de l'IO spawn).

  Ce prédicat est l'**unique gate canon** du boot des pods
  permanents, consulté par `Fleet.Starfleet.BootOrchestrator` (l'autorité de boot
  unique). `LCARS_BOOT_PERMANENT_AT_START=false` (runtime.exs) le met à
  `false` → BootOrchestrator wire les consumers + émet `fleet.boot_complete` mais
  ne spawn AUCUN pod permanent (mode dégradé/maintenance explicite). Le défaut
  (env absent) = `true` = boote — comportement prod nominal.
  """
  @spec auto_boot_enabled?() :: boolean()
  def auto_boot_enabled? do
    Application.get_env(:fleet_spawner, :boot_permanent_at_start, true) == true
  end

  # `persist_state/2` retirée — règle « écrivain unique » : seul
  # `Fleet.Spawner.Pod.StateFs.write_state_fs/1` (appelé par le `Pod`) écrit `state.json`. PermanentBoot
  # spawne le Pod et délègue l'écriture au gen_statem.

  # --- privé ---

  defp cap_profiles_dir do
    # Source UNIQUE alignée sur le LOADER (`Fleet.CapProfile.root_dir`) — sinon
    # PermanentBoot ÉNUMÈRE un dir (`05_data-canon/cap-profiles`) pendant que `Fleet.CapProfile.load`
    # CHARGE depuis un autre (`cap-profiles`) → un profil listé n'est pas chargeable (enum/load
    # désaccordés). L'override `:fleet_spawner, :cap_profiles_dir` reste (tests/déploiement non-standard).
    Application.get_env(:fleet_spawner, :cap_profiles_dir) || Fleet.CapProfile.root_dir()
  end

  # Énumère via la SOURCE UNIQUE `Fleet.CapProfile.list/1` — par prop
  # `metadata.name`, jamais par nom de fichier. Enum et `load` partagent ainsi la MÊME clé
  # (le name) → plus de désaccord enum↔load (un profil listé est toujours chargeable).
  defp list_roles(dir) do
    Fleet.CapProfile.list(dir)
  end

  # Charge TOUS les rôles, short-circuit au PREMIER échec de load (fail-loud, plus de skip
  # silencieux). Valide ainsi tout le catalogue au boot — un profil corrompu est attrapé avant même
  # d'être nécessaire. (Le filtrage permanent vient APRÈS, sur les cps chargés.)
  defp load_all(roles, loader) do
    case Enum.reduce_while(roles, {:ok, []}, fn role, {:ok, acc} ->
           case loader.(role) do
             {:ok, %Fleet.CapProfile{} = cp} ->
               {:cont, {:ok, [cp | acc]}}

             {:error, reason} ->
               Logger.error(
                 "PermanentBoot: cap-profile #{role} non chargeable (#{inspect(reason)}) — boot fail-loud"
               )

               {:halt, {:error, {:cap_profile_load_failed, role, reason}}}
           end
         end) do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp spawn_one(%Fleet.CapProfile{} = cp, spawner) do
    name = Fleet.CapProfile.name(cp)

    # pod_id DÉTERMINISTE (stable, sans suffixe timestamp) → re-spawn idempotent (même id : reap-orphan +
    # relance si mort, `{:already_started}` no-op si vivant ; plus de holder-leak/accumulation).
    pod_id = "permanent-#{name}"

    # Si une base existe pour ce rôle → boot-from-base (UUID FIXE porté par
    # la base + restore + `--resume`) → entrée Claude Desktop UNIQUE réutilisée à chaque boot + contexte
    # FRAIS (la base capturée hors-fleet, pas la session accumulée du run précédent). Sinon → recreate
    # (session neuve, comportement par défaut). Distinct de la recovery de CRASH (qui ne reprend jamais
    # une session — elle reroll FRESH) ; ici c'est le boot DÉLIBÉRÉ propre.
    opts = boot_opts(name, pod_id)

    case spawner.(cp, pod_id, opts) do
      {:ok, _pid} ->
        {:ok, pod_id}

      {:error, {:already_started, _pid}} ->
        Logger.info("PermanentBoot: permanent #{name} déjà vivant (#{pod_id}) — no-op idempotent")
        {:ok, pod_id}

      {:error, reason} ->
        # G9 : l'échec est RENDU (plus de nil filtré en silence) → boot_partial visible / respawn retry.
        Logger.error("PermanentBoot: spawn permanent #{name} échoué (#{inspect(reason)})")
        {:error, {name, reason}}
    end
  end

  # Opts de spawn d'un permanent.
  # Base présente (`priv/base_seeds/<role>.jsonl`) → boot-from-base : UUID FIXE = le `sessionId` PORTÉ par
  # la base (la base EST la source de l'UUID, pas de config séparée) → `--resume` ce même UUID à chaque
  # boot = UNE entrée Desktop, et `recall_seed_jsonl` restaure la base AVANT le launch = contexte frais.
  # Pas de base → `[pod_id:]` seul = recreate (session neuve).
  defp boot_opts(name, pod_id) do
    path = base_seed_path(name)

    case File.exists?(path) && base_seed_uuid(path) do
      uuid when is_binary(uuid) ->
        [pod_id: pod_id, session_id: uuid, resume: true, recall_seed_jsonl: path]

      _ ->
        [pod_id: pod_id]
    end
  end

  # Base seed d'un permanent : ancre résumable propre, capturée hors-fleet (claude pur), versionnée en priv.
  defp base_seed_path(name) do
    Path.join([:code.priv_dir(:fleet_spawner), "base_seeds", "#{name}.jsonl"])
  end

  # UUID fixe = 1er `sessionId` trouvé dans la base. nil si absent (→ boot_opts retombe sur recreate).
  defp base_seed_uuid(path) do
    path
    |> File.stream!()
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, %{"sessionId" => uuid}} when is_binary(uuid) -> uuid
        _ -> nil
      end
    end)
  rescue
    _ -> nil
  end
end

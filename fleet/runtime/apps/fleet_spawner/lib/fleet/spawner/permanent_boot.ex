defmodule Fleet.Spawner.PermanentBoot do
  @moduledoc """
  Boot des pods permanents Type 1 fleet-level au démarrage
  `lcars-fleet-v2.service` (DN `ring1/permanent-pods-boot.md` §"Contrat
  technique" + §"La décision" Type 1). Extension `fleet_spawner`
  chantier-6 (PAS refactor).

  ## Garde D-01 CRITIQUE

  `boot_at_start?/1` n'autorise un boot fleet_spawner que si
  `boot_at_start: true` **ET** `lifetime_scope: forever` **ET**
  `host_native != true`. Le 3e terme est la **garde anti-violation
  D-01** : `starfleet` (host_native: true, dérogation canon
  `derogations.md`) ne DOIT JAMAIS être spawné via fleet_spawner bwrap
  (il boote via `lcars-starfleet.service` systemd séparé). Garde
  défensive même si un profil host_native portait `boot_at_start: true`
  par erreur.

  ## Réalité chantier-6 (lecture, pas inférence — anti-M1)

  Le pseudo-code DN utilise `get_in(cp, [:spec, :invocation, :boot_at_start])`
  (clés atom). Le `%Fleet.CapProfile{}` réel a `spec :: map()` à **clés
  string** (`cap_profile.ex` L309 `spec: Map.get(raw, "spec", %{})`).
  Coder les atom-keys verbatim → `nil` → 0 pod booté silencieusement.
  Accès string-keyed ici.
  """

  require Logger

  @doc """
  Le cap-profile doit-il booter au démarrage fleet (Type 1) ?

  `true` ssi `spec.invocation.boot_at_start == true` ET
  `spec.invocation.lifetime_scope == "forever"` ET
  **`spec.invocation.host_native != true`** (garde D-01).
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
  Type 1 (garde `boot_at_start?/1` appliquée, D-01 exclu).
  """
  @spec select_permanent([Fleet.CapProfile.t()]) :: [Fleet.CapProfile.t()]
  def select_permanent(cap_profiles) when is_list(cap_profiles) do
    Enum.filter(cap_profiles, &boot_at_start?/1)
  end

  @doc """
  Boot des pods permanents Type 1 (DN §"Contrat technique"
  `boot_permanent_pods/0`). Invoqué post-readiness par l'**autorité unique**
  `Fleet.Starfleet.BootOrchestrator` (F-14, R7 — le hook `Fleet.Spawner.Application`
  qui l'invoquait aussi a été retiré pour éviter le double-boot).

  Énumère les rôles du répertoire cap-profiles → délègue le chargement+
  validation au loader canonique `Fleet.CapProfile.load/1` (DRY — pas de
  re-parse YAML, le pseudo-code DN `File.ls!+load_cap_profile` est
  illustratif) → garde `select_permanent/1` (D-01 exclu) → `spawn_pod/3`
  (signature réelle `(%CapProfile{}, ticket_id, opts)`).

  ## Échec de LOAD vs échec de SPAWN (F-052, Pattern A — révision doctrine 2026-06-17)

  **Un cap-profile qui ne CHARGE pas** (absent / YAML corrompu / schema invalide) = artefact de
  deploy cassé → **fail-loud** : `boot_permanent_pods/1` rend `{:error, {:cap_profile_load_failed,
  role, reason}}` (BootOrchestrator → `fleet.boot_failed`, pas `boot_complete` vert amputé). Avant,
  ces échecs étaient `Logger.warning + nil` → droppés en silence (« succès partiel acceptable », DN
  exit codes L296) — c'est le « truc blessé qu'on garde en vie » que la doctrine rejette.

  **Un échec de SPAWN** (bwrap/launch KO) reste **best-effort** : runtime, pas artefact de deploy →
  loggué (`Logger.error`) + `pod_id` omis, les autres pods bootent. (La détection « tous les pods
  permanents ont bien spawné » relève de la checklist de démarrage hors-runtime, cf. BL-053.)

  ## Écrivain unique state.json (BL-021 chantier 4 / DN permanent-pods-boot §C-3)

  PermanentBoot **spawne** mais **n'écrit pas** `state.json` — l'écriture est
  déléguée au `Fleet.Spawner.Pod` GenServer via `write_state_fs/1`. Seam
  `:state_writer` retiré (viol C-3 « un seul écrivain »).

  ## Seams (test-seam, élixir-thinking découpl. IO)
    * `:cap_profiles_dir` — répertoire scanné (défaut config
      `:fleet_spawner, :cap_profiles_dir`)
    * `:loader` — `(role :: String.t()) -> {:ok, cp} | {:error, term}`
      (défaut `&Fleet.CapProfile.load/1`)
    * `:spawner` — `(cp, ticket_id, opts) -> {:ok, pid} | {:error, term}`
      (défaut `&Fleet.Spawner.spawn_pod/3`)
  """
  @spec boot_permanent_pods(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def boot_permanent_pods(opts \\ []) when is_list(opts) do
    dir = Keyword.get(opts, :cap_profiles_dir) || cap_profiles_dir()
    loader = Keyword.get(opts, :loader, &Fleet.CapProfile.load/1)
    spawner = Keyword.get(opts, :spawner, &Fleet.Spawner.spawn_pod/3)

    with {:ok, roles} <- list_roles(dir),
         {:ok, cps} <- load_all(roles, loader) do
      pod_ids =
        cps
        |> select_permanent()
        |> Enum.map(&spawn_one(&1, spawner))
        |> Enum.reject(&is_nil/1)

      {:ok, pod_ids}
    else
      # F-052 : un load raté = deploy cassé → on propage tel quel (fail-loud). Distinct du dir
      # illisible (`list_roles`), classé `:cap_profiles_dir_unreadable`.
      {:error, {:cap_profile_load_failed, _role, _reason}} = err ->
        err

      {:error, reason} ->
        {:error, {:cap_profiles_dir_unreadable, reason}}
    end
  end

  @doc """
  Le boot des pods permanents est-il activé ? Config `:fleet_spawner,
  :boot_permanent_at_start` — **défaut `true`** (canon DN `lcars-fleet_service`
  §391 : « default true en prod, false en test » ; `false` désactive). Pur,
  testable (gate découplé de l'IO spawn — pattern elixir-thinking).

  **BL-028 (R7→clos)** : ce prédicat est l'**unique gate canon** du boot des pods
  permanents, consulté par `Fleet.Starfleet.BootOrchestrator` (l'autorité de boot
  unique depuis F-14). `LCARS_BOOT_PERMANENT_AT_START=false` (runtime.exs) le met à
  `false` → BootOrchestrator wire les consumers + émet `fleet.boot_complete` mais
  ne spawn AUCUN pod permanent (mode dégradé/maintenance explicite). Le défaut
  (env absent) = `true` = boote — comportement prod inchangé vs avant.
  """
  @spec auto_boot_enabled?() :: boolean()
  def auto_boot_enabled? do
    Application.get_env(:fleet_spawner, :boot_permanent_at_start, true) == true
  end

  # NB BL-021 chantier 4 — `persist_state/2` retirée (DN permanent-pods-boot §C-3
  # amendement « écrivain unique » : seul `Fleet.Spawner.Pod.write_state_fs/1` écrit
  # `state.json`. PermanentBoot spawne le Pod et délègue l'écriture au GenServer).

  # --- privé ---

  defp cap_profiles_dir do
    # F110/F111 (#582) : source UNIQUE alignée sur le LOADER (`Fleet.CapProfile.root_dir`) — sinon
    # PermanentBoot ÉNUMÈRE un dir (`05_data-canon/cap-profiles`) pendant que `Fleet.CapProfile.load`
    # CHARGE depuis un autre (`cap-profiles`) → un profil listé n'est pas chargeable (enum/load
    # désaccordés). L'override `:fleet_spawner, :cap_profiles_dir` reste (tests/déploiement non-standard).
    Application.get_env(:fleet_spawner, :cap_profiles_dir) || Fleet.CapProfile.root_dir()
  end

  # #582 (F110/F111) : énumère via la SOURCE UNIQUE `Fleet.CapProfile.list/1` — par prop
  # `metadata.name`, jamais par nom de fichier. Enum et `load` partagent ainsi la MÊME clé
  # (le name) → plus de désaccord enum↔load (un profil listé est toujours chargeable).
  defp list_roles(dir) do
    Fleet.CapProfile.list(dir)
  end

  # F-052 : charge TOUS les rôles, short-circuit au PREMIER échec de load (fail-loud, plus de skip
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

  defp spawn_one(%Fleet.CapProfile{metadata: meta} = cp, spawner) do
    name = Map.get(meta, "name") || Map.get(meta, :name) || "unknown"

    # BL-055 : pod_id DÉTERMINISTE (plus de `-<os_time>`). Le timestamp rendait chaque (re-)boot
    # NON-idempotent → un nouvel id à chaque tentative → l'ancien pod orpheline (flakiness « arch
    # re-spawné 1× », holder-leak, accumulation). Déterministe → un re-spawn retombe sur le MÊME id :
    # soit reap-orphan + relance propre (pod mort — `reap_orphan_pod` tourne à chaque launch), soit
    # `{:already_started}` (pod vivant = déjà booté → no-op idempotent). Sûr aujourd'hui : le gate
    # `:recovery_resume_enabled` est OFF par défaut → un vieux state.json réutilisé → `:recreate`
    # (session fraîche), pas de `--resume` foireux (le `--resume` propre = chantier home-persistance).
    pod_id = "permanent-#{name}"

    case spawner.(cp, pod_id, pod_id: pod_id) do
      {:ok, _pid} ->
        pod_id

      {:error, {:already_started, _pid}} ->
        Logger.info("PermanentBoot: permanent #{name} déjà vivant (#{pod_id}) — no-op idempotent")
        pod_id

      {:error, reason} ->
        Logger.error("PermanentBoot: spawn permanent #{name} échoué (#{inspect(reason)})")
        nil
    end
  end
end

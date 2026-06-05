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
  (signature réelle `(%CapProfile{}, ticket_id, opts)`). **Succès partiel
  acceptable** : un profil invalide / un spawn KO n'empêche pas les autres
  (DN exit codes L296).

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

    case list_roles(dir) do
      {:ok, roles} ->
        pod_ids =
          roles
          |> Enum.map(&load_one(&1, loader))
          |> Enum.reject(&is_nil/1)
          |> select_permanent()
          |> Enum.map(&spawn_one(&1, spawner))
          |> Enum.reject(&is_nil/1)

        {:ok, pod_ids}

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
    Application.get_env(
      :fleet_spawner,
      :cap_profiles_dir,
      "05_data-canon/cap-profiles"
    )
  end

  defp list_roles(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        roles =
          files
          |> Enum.filter(&String.ends_with?(&1, ".yaml"))
          |> Enum.map(&Path.basename(&1, ".yaml"))
          |> Enum.sort()

        {:ok, roles}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_one(role, loader) do
    case loader.(role) do
      {:ok, %Fleet.CapProfile{} = cp} ->
        cp

      {:error, reason} ->
        Logger.warning("PermanentBoot: cap-profile #{role} ignoré (#{inspect(reason)})")
        nil
    end
  end

  defp spawn_one(%Fleet.CapProfile{metadata: meta} = cp, spawner) do
    name = Map.get(meta, "name") || Map.get(meta, :name) || "unknown"
    ticket_id = "permanent-#{name}-#{System.os_time(:second)}"

    case spawner.(cp, ticket_id, pod_id: ticket_id) do
      {:ok, _pid} ->
        ticket_id

      {:error, reason} ->
        Logger.error("PermanentBoot: spawn permanent #{name} échoué (#{inspect(reason)})")
        nil
    end
  end
end

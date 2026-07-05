defmodule Fleet.CapProfile.Catalog do
  @moduledoc """
  Résolution + lecture des fichiers YAML du catalogue de cap-profiles.

  Cluster extrait de `Fleet.CapProfile`. Concern UNIQUE : le FRONT FS du domaine
  (scan du répertoire, décodage YAML, résolution d'un rôle/modop en map brute
  pré-`to_struct`). Le cœur `load`/`compose` appelle `read_role/1` et
  `read_modops/1` ; il ne touche jamais le FS lui-même.

  ## Invariant de sécurité — résolution par `metadata.name`, jamais par filename

  Un cap-profile est résolu par sa PROP interne `metadata.name` (via `name_index/1`),
  PAS par le nom de fichier (cosmétique). La source de vérité est la donnée, jamais
  le filesystem : `list/1`, `read_role/1` et l'énumérateur de boot partagent ainsi
  la MÊME clé (le name) → enum et load ne se désaccordent jamais (un profil listé
  est toujours chargeable). Un nom de modop (entrée non maîtrisée servant de segment
  de chemin) est confiné sous `<root>/modop/` via `Fleet.Slug.confined_join/2`
  (fail-closed : un `..`/`/` n'atteint jamais le FS).

  ## Surface publique + re-export hors-app

  `list/1` et `root_dir/0` sont consommés HORS de l'app (`Fleet.Spawner.PermanentBoot`
  énumère + aligne son dir ; `Fleet.Observation.Deck` liste les rôles du dashboard).
  `Fleet.CapProfile` les ré-expose en `defdelegate` — l'API publique consommée hors-app
  ne bouge PAS. `read_role/1` et `read_modops/1` sont publics pour le cœur (même app).

  ## Sens de dépendance UNIQUE (pas de cycle)

  Ce module dépend de `Fleet.CapProfile.Schema` (validation des fragments modop dans
  `read_modops/1`) et de `Fleet.Slug` (confinement) — tous deux en AMONT, aucun
  n'appelle Catalog. Le cœur `Fleet.CapProfile.load`/`compose` appelle ce module
  (runtime-dep). Pas de cycle.

  ## Configuration

  `root_dir/0` lit la clé env `:fleet_cap_profile, :root_dir` (les tests la pilotent
  via `Application.put_env/3`), défaut = le canon BUNDLÉ résolu par
  `:code.priv_dir(:fleet_cap_profile)` (résout en release comme en dev, sans env).
  """

  require Logger

  # Validation JSON-schema des fragments modop (clés réservées + conformité). En AMONT :
  # Schema n'appelle rien ici (pas de cycle). Deux appels FQ sous credo AliasUsage, aliasé
  # pour la lisibilité du cluster.
  alias Fleet.CapProfile.Schema

  # ============================================================
  # Résolution de rôle (par metadata.name)
  # ============================================================

  @doc """
  Résout un cap-profile par sa PROP `metadata.name` (pas par nom de fichier — celui-ci est
  cosmétique) et retourne la map brute (pré-`to_struct`). Source de vérité = la donnée,
  jamais le filesystem (cf. `list/1`).

  ## Exit codes
    * `{:ok, raw}` — le rôle existe dans le catalogue.
    * `{:error, :not_found}` — aucun profil ne porte ce `name`.
    * `{:error, :invalid_schema}` — catalogue corrompu (un YAML non-décodable) →
      on ne peut PAS résoudre par name. Le contrat `load`/`compose` classe « YAML mal
      formé » en `:invalid_schema` (pas `:not_found`, qui ferait croire le rôle absent).
  """
  @spec read_role(String.t()) :: {:ok, map()} | {:error, :not_found | :invalid_schema}
  def read_role(role) do
    case name_index(root_dir()) do
      {:ok, index} ->
        case Map.fetch(index, role) do
          {:ok, raw} -> {:ok, raw}
          :error -> {:error, :not_found}
        end

      {:error, {:invalid_yaml, _path}} ->
        {:error, :invalid_schema}
    end
  end

  @doc """
  Liste les NOMS (`metadata.name`) des cap-profiles du catalogue (`dir`, défaut `root_dir/0`).

  **Source UNIQUE** : tout énumérateur (`Fleet.Spawner.PermanentBoot`) ET `Fleet.CapProfile.load/1`
  résolvent par CETTE clé — la prop `name`, **jamais** le nom de fichier (cosmétique). Trié.
  Collision de `name` entre deux fichiers → `{:error, :name_collision}` (fail-loud : pas de résolution
  silencieuse au petit bonheur du filesystem).
  """
  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(dir \\ root_dir()) do
    # Dir absent/illisible = erreur (config cassée) — distinct d'un catalogue vide ({:ok, []}).
    # `Path.wildcard` confond les deux ; `File.dir?` tranche. (`load/1` passe par `read_role` →
    # `name_index` directement → un dir absent y donne `:not_found`, pas `:enoent` — le rôle est
    # juste introuvable.)
    if File.dir?(dir) do
      with {:ok, index} <- name_index(dir) do
        {:ok, index |> Map.keys() |> Enum.sort()}
      end
    else
      {:error, :enoent}
    end
  end

  # Index `metadata.name => raw` en scannant `<dir>/*.yaml` + `<dir>/archivistes/*.yaml` +
  # `<dir>/monks/*.yaml` (les profils Memory-X canon vivent sous `monks/` ; PermanentBoot — qui
  # énumère via `list/1` — doit les voir). Le `modop/` reste exclu : les overlays n'ont pas d'identité
  # de rôle. Fragment sans `metadata.name` → ignoré (baseline/overlay).
  # Collision `name` → fail-loud (`:name_collision`).
  #
  # Un YAML NON-DÉCODABLE dans le catalogue n'est PAS skippé en silence (sinon le rôle serait
  # INVISIBLE de l'index → `load` le verrait `:not_found` (rôle absent) au lieu de `:invalid_schema`
  # (rôle corrompu), et `list/1` (énuméré par PermanentBoot) l'amputerait du boot sans bruit → deploy
  # « vert » incomplet). Un fichier corrompu = artefact de deploy cassé → on propage
  # `{:error, {:invalid_yaml, path}}` (fail-loud). Conséquence assumée : un seul fichier illisible
  # empoisonne tout l'index (catalogue corrompu = on n'en charge AUCUN) — cohérent avec « on ne sauve
  # pas un truc blessé ».
  defp name_index(dir) do
    files =
      Path.wildcard(Path.join(dir, "*.yaml")) ++
        Path.wildcard(Path.join([dir, "archivistes", "*.yaml"])) ++
        Path.wildcard(Path.join([dir, "monks", "*.yaml"]))

    Enum.reduce_while(files, {:ok, %{}}, fn path, {:ok, acc} ->
      case decode_yaml(path) do
        {:ok, raw} ->
          case get_in(raw, ["metadata", "name"]) do
            name when is_binary(name) and name != "" ->
              if Map.has_key?(acc, name) do
                Logger.error("CapProfile: collision metadata.name #{inspect(name)} (#{path})")
                {:halt, {:error, :name_collision}}
              else
                {:cont, {:ok, Map.put(acc, name, raw)}}
              end

            _ ->
              {:cont, {:ok, acc}}
          end

        {:error, reason} ->
          Logger.error(
            "CapProfile: YAML illisible #{path} (#{inspect(reason)}) — catalogue corrompu"
          )

          {:halt, {:error, {:invalid_yaml, path}}}
      end
    end)
  end

  # ============================================================
  # Lecture des modops
  # ============================================================

  @doc """
  Lit et valide les fragments modop nommés (ordre déclaré préservé), retourne les maps brutes.

  Chaque nom (entrée non maîtrisée, servant de COMPOSANT de chemin `modop/<name>/profile.yaml`)
  est casté en slug et confiné sous `<root>/modop/` AVANT tout `Path.join` — un nom malformé
  (`..`/`/`) n'atteint jamais le FS (fail-closed → `:invalid_modop`). Chaque fragment est validé
  via `Fleet.CapProfile.Schema` (clés réservées + JSON-schema modop).

  ## Exit codes
    * `{:ok, [raw]}` — tous les modops lus et conformes.
    * `{:error, :modop_not_found}` — un modop nommé est absent (loggé).
    * `{:error, :invalid_modop}` — nom non confiné, clé réservée, ou fragment non conforme.
    * `{:error, :invalid_schema}` / `{:error, :schema_unavailable}` — décodage/schema (cf. Schema).
  """
  @spec read_modops([String.t()]) :: {:ok, [map()]} | {:error, term()}
  def read_modops(modop_set) when is_list(modop_set) do
    result =
      Enum.reduce_while(modop_set, {:ok, []}, fn name, {:ok, acc} ->
        # Le nom de modop vient du catalogue / d'un composeur (entrée non maîtrisée) et sert de
        # COMPOSANT de chemin (`modop/<name>/profile.yaml`). Un nom avec `..`/`/` traverserait hors du
        # modop_root (charger un YAML arbitraire de l'hôte comme « modop »). On le caste en slug AVANT
        # tout `Path.join` ET on confine la feuille sous `<root>/modop/` : un nom malformé n'atteint
        # jamais le FS (fail-closed → `:invalid_modop`, comme un fragment réservé/non conforme).
        modop_root = Path.join(root_dir(), "modop")

        with {:ok, dir} <- Fleet.Slug.confined_join(modop_root, name) do
          path = Path.join(dir, "profile.yaml")

          if File.exists?(path) do
            with {:ok, raw} <- decode_yaml(path),
                 :ok <- Schema.validate_modop_keys(raw),
                 :ok <- Schema.validate(raw, :modop) do
              {:cont, {:ok, [raw | acc]}}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end
          else
            Logger.warning("CapProfile: modop not found: #{inspect(name)} at #{path}")
            {:halt, {:error, :modop_not_found}}
          end
        else
          {:error, _slug_or_escape} ->
            Logger.warning(
              "CapProfile: modop name non confiné (slug/traversal) : #{inspect(name)} — refusé"
            )

            {:halt, {:error, :invalid_modop}}
        end
      end)

    case result do
      {:ok, modops} -> {:ok, Enum.reverse(modops)}
      error -> error
    end
  end

  # ============================================================
  # Décodage YAML + racine du catalogue
  # ============================================================

  defp decode_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, :invalid_schema}
      {:error, _reason} -> {:error, :invalid_schema}
    end
  end

  @doc """
  Racine du catalogue cap-profiles (`<root_dir>/<role>.yaml`). **Source UNIQUE** : tout
  énumérateur (ex. `Fleet.Spawner.PermanentBoot`) DOIT scanner ce dir, sinon enum et load
  se désaccordent.
  """
  @spec root_dir() :: String.t()
  def root_dir do
    # Un :root_dir explicitement nil (ex. fuite d'env cross-test en umbrella) ne doit JAMAIS
    # atteindre Path.join → coalesce vers le défaut (état nil rendu inoffensif au boundary).
    # Défaut = le priv BUNDLÉ (`:code.priv_dir`) → résout en RELEASE (lib/fleet_cap_profile-vsn/priv/…)
    # comme en dev (_build/…/priv) SANS aucun env. L'ancien défaut `"cap-profiles"` (relatif au CWD) n'a
    # jamais été correct hors d'un `LCARS_CAPPROFILES_ROOT` explicite → `:enoent` en release (étanchéité).
    Application.get_env(:fleet_cap_profile, :root_dir) ||
      Path.join(to_string(:code.priv_dir(:fleet_cap_profile)), "canon/cap-profiles")
  end
end

defmodule Fleet.CapProfile do
  @moduledoc """
  Capability Profile composer/loader/validator (LCARS schema v2.5).

  Pure data transformer: YAML on disk → composed `%Fleet.CapProfile{}`
  struct. No process, no state. Three public functions (`load/1`,
  `compose/2`, `validate/1`) implementing the `Fleet.CapProfile.Loader`
  behaviour.

  Schema is pinned to `apiVersion: lcars/v2.5`. Every profile is matched
  against `priv/schema/cap-profile-v2.5.json` at load time. Modops are
  matched against `priv/schema/modop-profile.json` (strict — reserved
  keys forbidden, so a modop cannot override the base profile's
  containment/name/kind).

  Composition is deterministic: deep-merge last-wins in declared order,
  canonical JSON encoding (recursive key sort), `:crypto` sha256.
  """

  @behaviour Fleet.CapProfile.Loader

  # Cluster de validation JSON-schema (conformité structurelle), en AMONT du cœur.
  # `load`/`compose`/`read_modops` y délèguent ; pas de cycle (Schema n'appelle rien ici).
  alias Fleet.CapProfile.Schema

  require Logger

  # Pas de champ `api_version` : le versioning du schéma est porté par le code
  # (release v2), pas par un champ embarqué dans le YAML.
  # @enforce_keys : un cap-profile n'existe pas sans ses trois faces (kind/metadata/spec).
  # Le boundary unique de construction `to_struct/1` les peuple toujours → additif, ne casse
  # pas la construction normale ; ce qu'il interdit = un `%CapProfile{}` partiel bricolé hors load.
  @enforce_keys [:kind, :metadata, :spec]
  defstruct [:kind, :metadata, :spec]

  @type t :: %__MODULE__{
          kind: String.t(),
          metadata: map(),
          spec: map()
        }

  # ============================================================
  # Loader behaviour
  # ============================================================

  @doc """
  Charge un cap-profile YAML pour le rôle donné, valide contre le schema
  `priv/schema/cap-profile-v2.5.json`.

  Path resolution : `<root_dir>/<role>.yaml` puis fallback
  `<root_dir>/archivistes/<role>.yaml` (cohérence v1.5).

  ## Exit codes
    * `{:ok, %Fleet.CapProfile{}}` — chargement et validation OK
    * `{:error, :not_found}` — fichier YAML absent
    * `{:error, :invalid_schema}` — YAML mal formé OU non-conforme au schema
    * `{:error, :schema_unavailable}` — fichier schema priv absent ou corrompu
  """
  @impl Fleet.CapProfile.Loader
  @spec load(String.t()) :: {:ok, t()} | {:error, atom() | String.t()}
  def load(role) when is_binary(role) do
    with {:ok, raw} <- read_role_yaml(role),
         :ok <- Schema.validate(raw, :cap_profile) do
      {:ok, to_struct(raw)}
    end
  end

  @doc """
  Compose un cap-profile à partir d'un rôle de base et d'une liste ordonnée
  de modops. Deep-merge last-wins, ordre déclaré = précédence.

  Le résultat est revalidé contre le schema cap-profile post-merge.

  ## Exit codes
    * `{:ok, %Fleet.CapProfile{}}` — composition OK
    * `{:error, :not_found}` — rôle de base absent
    * `{:error, :modop_not_found}` — au moins un modop nommé est absent
      (le nom du modop manquant est loggé via `Logger.warning/1`)
    * `{:error, :invalid_schema}` — base ou résultat post-merge non-conforme
    * `{:error, :invalid_modop}` — modop YAML invalide ou clés réservées
    * `{:error, :schema_unavailable}` — fichier schema priv absent ou corrompu
  """
  @impl Fleet.CapProfile.Loader
  @spec compose(String.t(), [String.t()]) :: {:ok, t()} | {:error, term()}
  def compose(role, modop_set) when is_binary(role) and is_list(modop_set) do
    with {:ok, base} <- read_role_yaml(role),
         :ok <- Schema.validate(base, :cap_profile),
         {:ok, modops} <- read_modops(modop_set),
         merged <- Enum.reduce(modops, base, &deep_merge_last_wins(&2, &1)),
         :ok <- Schema.validate(merged, :cap_profile) do
      {:ok, to_struct(merged)}
    end
  end

  @doc """
  Valide un `%Fleet.CapProfile{}` contre les invariants G24 **purs**
  (canon cap-profile v2.5 + gate containment). Fonction pure : aucune
  lecture de process ni de FS (cf. moduledoc) — même struct ⇒ même verdict.

  ## Invariants implémentés
    * Structuraux : `:g24_1` (containment), `:g24_3` (kind), `:g24_4`
      (lifetime_scope enum), `:g24_6` (modop incompatible), `:g24_8`
      (metadata.name), `:g24_9_strict`/`:g24_9_prefix` (deny-list containment
      = minimum de `disallowedTools`).
    * Belt-and-suspenders v2.5 (doublonnent le JSON-schema `allOf` pour un
      atome d'erreur verbeux côté Elixir) : `:g24_10` (boot_at_start ⟹
      forever), `:g24_11` (subagent_template ⟹ one-shot), `:g24_12`
      (host_native ⟹ containment none).
    * Couverture NON portée par le schéma : `:g24_14` (pairing
      monk_registry ⟺ monk_instance — both-or-neither).

  ## Hors `validate/1` (exclus parce qu'impurs — le contrat est « pure data transformer »)
    * **g24_13** (`mcp_channels` non-vide ⟹ `Fleet.MCP.Server` vivant) :
      check de **liveness runtime**, donc impur (non-déterministe) — viole
      le contrat « pure data transformer ». Concern de spawn-time, pas un
      invariant statique du profil. La liveness est bornée au boundary de
      spawn (le monde valide), pas dans le validateur pur.
    * **g24_12 `system_user` privilégié** : le pseudo-code l'exigeait mais
      `system_user` n'existe pas au schéma v2.5 ; g24_12 réel = `containment:
      none` seul, aligné sur l'`allOf` JSON.
    * **g24_14 existence FS du registry + lookup `monk_instance`** : I/O,
      donc impur — c'est un check load-time (`compose/2`), pas `validate/1`.

  ## Exit codes
    * `:ok` — tous les invariants passent
    * `{:error, [violation_codes]}` — liste des invariants violés, atomes
      parmi `:g24_1`, `:g24_3`, `:g24_4`, `:g24_6`, `:g24_8`,
      `:g24_9_strict`, `:g24_9_prefix`, `:g24_10`, `:g24_11`, `:g24_12`,
      `:g24_14`
  """
  @impl Fleet.CapProfile.Loader
  @spec validate(t()) :: :ok | {:error, [atom()]}
  def validate(%__MODULE__{} = profile) do
    # Le cluster d'invariants PURS (une fonction par check) vit dans
    # `Fleet.CapProfile.Invariants`. Ici on ne garde QUE le contrat de retour
    # single-authority consommé hors-app : `[]` ⇒ `:ok`, sinon `{:error, [codes]}`.
    case Fleet.CapProfile.Invariants.violations(profile) do
      [] -> :ok
      violations -> {:error, violations}
    end
  end

  # ============================================================
  # Public helpers
  # ============================================================

  @doc """
  Traduit les entrées sémantiques `spec.scope.git_ops_denied` (ex. `"push --force"`,
  `"reset --hard"`) en patterns `disallowedTools` claude CLI de la forme
  `Bash(git <entrée>:*)`. Les entrées vides/non-binaires sont ignorées. Ordre d'entrée
  préservé. Pure.

  Mécanisme générique catalogue → claude CLI : ce qui était une ligne déclarative
  validée G24 isolément devient une contrainte effectivement enforced par claude
  CLI au lancement du pod (disallow l'emporte sur allow sur le même pattern).
  """
  @spec git_ops_denied_patterns(t()) :: [String.t()]
  def git_ops_denied_patterns(%__MODULE__{spec: spec}) do
    spec
    |> get_in(["scope", "git_ops_denied"])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&"Bash(git #{&1}:*)")
  end

  @doc """
  Retourne un `%CapProfile{}` dont `spec.scope.disallowedTools` est augmenté :
  - des patterns du **baseline universel** (`_baseline-git-denied.yaml`,
    intangibles selon principe directeur)
  - PUIS des patterns issus de `git_ops_denied_patterns/1` (cap-profile worker
    spécifique).
  Union dédupliquée, ordre préservé : existants, baseline, profile.
  Idempotent.

  Point d'application : `Fleet.Spawner.Pod.do_allocate/1` au moment d'écrire
  `.cap-profile.json` dans le pod, pour que `claude_launch.sh` reçoive la
  liste déjà résolue.
  """
  @spec with_resolved_disallowed_tools(t()) :: t()
  def with_resolved_disallowed_tools(%__MODULE__{spec: spec} = profile) do
    baseline_patterns = baseline_git_ops_denied_patterns()
    profile_patterns = git_ops_denied_patterns(profile)
    existing = get_in(spec, ["scope", "disallowedTools"]) || []
    augmented = Enum.uniq(existing ++ baseline_patterns ++ profile_patterns)

    new_scope =
      spec
      |> Map.get("scope", %{})
      |> Map.put("disallowedTools", augmented)

    %{profile | spec: Map.put(spec, "scope", new_scope)}
  end

  @doc """
  Patterns `disallowedTools` issus du baseline universel
  (`priv/canon/cap-profiles/_baseline-git-denied.yaml`). Patterns
  intangibles refusés à TOUS les workers indépendamment du cap-profile —
  retirer un pattern = décision archi explicite (édit du fichier baseline,
  pas option de cap-profile).

  **Raise** si le fichier baseline est absent, illisible, ou de format
  invalide. La baseline est doctrinalement "intangible" : un fail-open
  silencieux (retour `[]`) désactiverait la denylist universelle sans
  alerter, contradictoire avec l'intention → fail-closed. Le caller
  (`pod.ex do_allocate`) catch via `rescue` et transitionne `:failed`
  proprement.

  Pure modulo I/O fichier ; pas de cache (lu une fois par résolution cap-
  profile, fréquence faible).
  """
  @spec baseline_git_ops_denied_patterns() :: [String.t()]
  def baseline_git_ops_denied_patterns do
    load_baseline_git_ops_denied!()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&"Bash(git #{&1}:*)")
  end

  # Baseline priv IMMUABLE : read+parse une fois, caché en `:persistent_term`
  # (lazy-init ; une erreur n'est pas cachée — le bang re-raise au prochain appel).
  defp load_baseline_git_ops_denied! do
    key = {__MODULE__, :baseline_git_ops_denied}

    case :persistent_term.get(key, :miss) do
      :miss ->
        entries = read_baseline_git_ops_denied!()
        :persistent_term.put(key, entries)
        entries

      entries ->
        entries
    end
  end

  defp read_baseline_git_ops_denied! do
    path =
      :fleet_cap_profile
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("canon/cap-profiles/_baseline-git-denied.yaml")

    case YamlElixir.read_from_file(path) do
      {:ok, %{"git_ops_denied" => entries}} when is_list(entries) ->
        entries

      {:ok, _other} ->
        raise "fleet_cap_profile baseline #{path} : clé `git_ops_denied` absente ou format invalide (baseline intangible — fail-closed)"

      {:error, reason} ->
        raise "fleet_cap_profile baseline #{path} absent ou corrompu (#{inspect(reason)}) (baseline intangible — fail-closed)"
    end
  end

  @doc """
  Le mode de containment du profil (`metadata.containment`). `"bwrap"` = pod sandboxé (RO mounts +
  tmpfs /home + bind credentials, défaut) ; `"none"` = host-native (architect-interactif, starfleet —
  le pod tourne SUR L'HÔTE *as* l'humain, hors sandbox = le pouvoir le plus fort de la fleet).

  **Source UNIQUE** de cette lecture (le spawner sélectionne le launcher N0 dessus, l'API spawn
  l'interdit host-native). Défaut `"bwrap"` si la clé est absente : containment manquant ⇒ on présume
  le mode confiné, jamais l'hôte — un trou de config ne doit JAMAIS ouvrir l'hôte par défaut.
  """
  @spec containment(t()) :: String.t()
  def containment(%__MODULE__{metadata: meta}) when is_map(meta),
    do: Map.get(meta, "containment") || Map.get(meta, :containment) || "bwrap"

  def containment(%__MODULE__{}), do: "bwrap"

  @doc """
  Le `name` du profil (`metadata["name"]`) — l'identité du rôle/pod portée par le cap-profile.

  **Source UNIQUE** de cette lecture. Lit la clé STRING `"name"` (l'invariant `stringify_keys` du
  boundary `to_struct/1` garantit les clés string en profondeur).

  **Sans défaut fabriqué** : un cap-profile sans name est un état que le domaine interdit. Si `name`
  est absent ou vide (`nil`/`""`/clé manquante), on **raise** (fail-loud) — on ne fabrique JAMAIS un
  `"unknown"`/`"worker"` qui masquerait le trou. À l'usage normal le `minLength: 1` du schema le
  garantit déjà à `load` ; cet accesseur est le filet pour un struct construit hors `load`.
  """
  @spec name(t()) :: String.t()
  def name(%__MODULE__{metadata: %{"name" => name}}) when is_binary(name) and byte_size(name) > 0,
    do: name

  def name(%__MODULE__{}), do: raise(ArgumentError, "CapProfile sans name — état interdit")

  @doc """
  Index du rôle dans l'UUID hexspeak (`metadata.role_index`, 0..15) — le nibble `R` du session_id
  déterministe. C'est ICI que vit le catalogue rôle → slot : l'encodeur `Fleet.Spawner.SessionId`
  ne catalogue plus, il reçoit cet index. **Source UNIQUE** de cette lecture.

  **Sans défaut fabriqué** : un cap-profile sans `role_index` entier n'est pas un rôle catalogué (pas
  d'identité hexspeak à reconstruire) → on **raise** (fail-loud, comme `name/1`). Pour brancher SANS
  risquer le raise, tester d'abord la présence avec `catalogued?/1`.
  """
  @spec role_index(t()) :: 0..15
  def role_index(%__MODULE__{metadata: %{"role_index" => r}}) when is_integer(r), do: r

  def role_index(%__MODULE__{}),
    do: raise(ArgumentError, "CapProfile sans role_index entier — pas un rôle catalogué")

  @doc """
  Le rôle est-il un TIER PROTÉGÉ (`metadata.protected`) ? `true` = épargné par le kill des workers
  (`pkill -f 1badcafe`) et encodé `0badcafe` dans le session_id. **Source UNIQUE** de cette lecture.

  Défaut `false` (non-protégé) si la clé est absente ou non-booléenne : défaut conservateur — un trou
  de config ne PROMEUT jamais un rôle au tier protégé.
  """
  @spec protected?(t()) :: boolean()
  def protected?(%__MODULE__{metadata: %{"protected" => p}}) when is_boolean(p), do: p
  def protected?(%__MODULE__{}), do: false

  @doc """
  Le rôle est-il FLEET-LEVEL (`metadata.fleet_level`) ? `true` = une seule instance, repo toujours
  `0000` (pas de dimension projet). `false` = project-bound → le session_id EXIGE le repo (sinon
  collision inter-projet). **Source UNIQUE** de cette lecture.

  Défaut `false` (project-bound) si la clé est absente ou non-booléenne : défaut conservateur — on ne
  promeut jamais un rôle au statut fleet-level (repo 0000) par accident.
  """
  @spec fleet_level?(t()) :: boolean()
  def fleet_level?(%__MODULE__{metadata: %{"fleet_level" => f}}) when is_boolean(f), do: f
  def fleet_level?(%__MODULE__{}), do: false

  @doc """
  Granularité d'identité/slot du rôle (`metadata.slot_scope`) — axe ORTHOGONAL à `lifetime_scope`.
  `"project"` : pod_id par (repo, rôle) → UNE identité par projet → UN slot Desktop stable (cwd +
  session-id figés), dispatch sérialisé par (repo, rôle) (engineer, singletons fleet-level). `"instance"` :
  pod_id par (repo, numéro, rôle) → fan-out par issue/PR (juges éphémères). **Source UNIQUE** de cette
  lecture : `Fleet.Pilot.StepDispatcher` choisit `PodId.for_repo` vs `for_issue`/`for_pr` là-dessus.

  **Sans défaut fabriqué** (comme `role_index/1` / `name/1`) : la politique de slot est une propriété de
  routage déclarée explicitement par CHAQUE rôle — un profil sans `slot_scope ∈ {project, instance}` est
  un trou de catalogue → on **raise** (fail-loud), jamais d'inférence silencieuse en code.
  """
  @spec slot_scope(t()) :: String.t()
  def slot_scope(%__MODULE__{metadata: %{"slot_scope" => s}}) when s in ["project", "instance"],
    do: s

  def slot_scope(%__MODULE__{}),
    do:
      raise(
        ArgumentError,
        "CapProfile sans metadata.slot_scope ∈ {project, instance} — politique de slot non déclarée " <>
          "(catalogue-only, pas de défaut : déclarer le scope dans le cap-profile du rôle)"
      )

  @doc """
  Le cap-profile est-il un rôle CATALOGUÉ (porte un `role_index` entier) ? Prédicat SANS raise — c'est
  le test de présence que `Fleet.Spawner.Pod.deterministic_session_id` interroge AVANT d'appeler
  `role_index/1` : un rôle non catalogué (ad-hoc, hors-fleet) n'a pas d'identité déterministe à
  reconstruire → un session_id random y est légitime, pas une erreur.
  """
  @spec catalogued?(t()) :: boolean()
  def catalogued?(%__MODULE__{metadata: meta}) when is_map(meta),
    do: is_integer(Map.get(meta, "role_index"))

  def catalogued?(%__MODULE__{}), do: false

  @doc """
  Returns the canonical JSON sha256 (lowercase hex) of a composed map
  or struct. Used by callers to assert deterministic composition.
  Underlying map iteration order is irrelevant — the canonical encoder
  sorts keys recursively before encoding.
  """
  @spec sha256(t() | map()) :: String.t()
  def sha256(%__MODULE__{} = profile), do: profile |> struct_to_map() |> sha256()

  def sha256(map) when is_map(map) do
    map
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # ============================================================
  # I/O
  # ============================================================

  # Résout un cap-profile par sa PROP `metadata.name` (pas par nom de fichier — celui-ci est
  # cosmétique). Source de vérité = la donnée, jamais le filesystem (cf. `list/1`).
  defp read_role_yaml(role) do
    case name_index(root_dir()) do
      {:ok, index} ->
        case Map.fetch(index, role) do
          {:ok, raw} -> {:ok, raw}
          :error -> {:error, :not_found}
        end

      # Catalogue corrompu (un YAML non-décodable) → on ne peut PAS résoudre par name.
      # Le contrat load/compose (moduledoc) classe « YAML mal formé » en `:invalid_schema` — pas
      # `:not_found` (qui ferait croire le rôle absent). On honore le contrat.
      {:error, {:invalid_yaml, _path}} ->
        {:error, :invalid_schema}
    end
  end

  @doc """
  Liste les NOMS (`metadata.name`) des cap-profiles du catalogue (`dir`, défaut `root_dir/0`).

  **Source UNIQUE** : tout énumérateur (`Fleet.Spawner.PermanentBoot`) ET `load/1` résolvent par
  CETTE clé — la prop `name`, **jamais** le nom de fichier (cosmétique). Trié.
  Collision de `name` entre deux fichiers → `{:error, :name_collision}` (fail-loud : pas de résolution
  silencieuse au petit bonheur du filesystem).
  """
  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(dir \\ root_dir()) do
    # Dir absent/illisible = erreur (config cassée) — distinct d'un catalogue vide ({:ok, []}).
    # `Path.wildcard` confond les deux ; `File.dir?` tranche. (`load/1` passe par `name_index`
    # directement → un dir absent y donne `:not_found`, pas `:enoent` — le rôle est juste introuvable.)
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

  defp read_modops(modop_set) do
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
            Logger.warning("modop not found: #{inspect(name)} at #{path}")
            {:halt, {:error, :modop_not_found}}
          end
        else
          {:error, _slug_or_escape} ->
            Logger.warning("modop name non confiné (slug/traversal) : #{inspect(name)} — refusé")
            {:halt, {:error, :invalid_modop}}
        end
      end)

    case result do
      {:ok, modops} -> {:ok, Enum.reverse(modops)}
      error -> error
    end
  end

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

  # ============================================================
  # Deep merge & canonical encoding
  # ============================================================

  defp deep_merge_last_wins(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, lv, rv ->
      if is_map(lv) and is_map(rv), do: deep_merge_last_wins(lv, rv), else: rv
    end)
  end

  defp deep_merge_last_wins(_left, right), do: right

  defp canonical_json(map) when is_map(map) and not is_struct(map) do
    pairs =
      map
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> {to_string(k), canonical_json(v)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> Jason.encode!(k) <> ":" <> v end)
      |> Enum.join(",")

    "{" <> pairs <> "}"
  end

  defp canonical_json(list) when is_list(list) do
    inner = list |> Enum.map(&canonical_json/1) |> Enum.join(",")
    "[" <> inner <> "]"
  end

  defp canonical_json(other), do: Jason.encode!(other)

  # ============================================================
  # Struct conversion
  # ============================================================

  @doc """
  Accesseur canon du `lifetime_scope` d'un cap-profile (`spec.invocation.lifetime_scope`,
  schéma v2.5). **Source unique** : l'extraction ne doit PAS être ré-implémentée chez les
  lecteurs (spawner/step_runner/sp_builder/pod) — sinon défauts incohérents. `default` par
  défaut `"one-shot"` (le défaut canon) ; les lecteurs qui veulent distinguer l'absence
  (ex. brief_guard) passent `nil`.
  """
  @spec lifetime_scope(t(), term()) :: String.t() | term()
  def lifetime_scope(%__MODULE__{spec: spec}, default \\ "one-shot") do
    get_in(spec, ["invocation", "lifetime_scope"]) || default
  end

  @doc """
  Accesseur canon du `deliverable_mode` (`spec.deliverable_mode`, schéma v2.5). **Source unique** :
  la sélection du mode de publication (`Fleet.Pipeline.Deliverable.publish/1`) se lit ICI, pas
  ré-implémentée chez les lecteurs. `default` `"payload"` (le défaut canon, back-compat : un profil
  sans champ = le-système-écrit-le-payload). Les code-rôles déclarent `git_native`.
  """
  @spec deliverable_mode(t(), term()) :: String.t() | term()
  def deliverable_mode(%__MODULE__{spec: spec}, default \\ "payload") do
    get_in(spec, ["deliverable_mode"]) || default
  end

  @doc """
  Accesseur canon du `brief_kind` (`spec.brief_kind`, schéma v2.5). Dual D'ENTRÉE de
  `deliverable_mode` (sortie) : il déclare la **forme du brief** que le rôle reçoit, par catalogue
  et PAS par nom magique de rôle.

    * `"worker"` (défaut) — le brief est une instruction exécutable (corps de l'issue) : le rôle
      AGIT (engineer, architect…).
    * `"judge"` — le rôle JUGE : il reçoit un `GateBrief` structurellement **désamorcé** (contexte + livrable +
      contrat de verdict, AUCUNE instruction exécutable — sinon le juge exécuterait le body). Le gatekeeper le déclare.

  `default` `"worker"` est **fail-safe** : un profil sans champ reçoit un brief exécutable (le cas
  ultra-majoritaire) ; jamais l'inverse (un worker désamorcé par erreur ne ferait rien). Un rôle
  juge DOIT déclarer `judge` explicitement — la judge-ness est une propriété de sécurité (rendue
  structurellement vraie, jamais inférée).
  """
  @spec brief_kind(t(), term()) :: String.t() | term()
  def brief_kind(%__MODULE__{spec: spec}, default \\ "worker") do
    get_in(spec, ["brief_kind"]) || default
  end

  defp to_struct(raw) when is_map(raw) do
    %__MODULE__{
      kind: Map.get(raw, "kind"),
      metadata: stringify_keys(Map.get(raw, "metadata", %{})),
      spec: stringify_keys(Map.get(raw, "spec", %{}))
    }
  end

  # `metadata`/`spec` sont garantis à **clés STRING en profondeur**, ici à la
  # production (boundary unique `to_struct`). Les lecteurs (ProjectBootstrap,
  # sp_builder, spawner) accèdent en clés string SANS double-lookup atom|string
  # défensif — la forme incohérente (clés mixtes) devient structurellement
  # impossible en aval. Les structs (DateTime…) et scalaires passent tels quels ;
  # seules les CLÉS de map sont stringifiées.
  defp stringify_keys(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp struct_to_map(%__MODULE__{} = p) do
    %{
      "kind" => p.kind,
      "metadata" => p.metadata,
      "spec" => p.spec
    }
  end
end

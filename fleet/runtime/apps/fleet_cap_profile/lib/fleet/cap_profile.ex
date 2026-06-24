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

  require Logger

  # Pas de champ `api_version` : le versioning du schéma est porté par le code
  # (release v2), pas par un champ embarqué dans le YAML.
  defstruct [:kind, :metadata, :spec]

  @type t :: %__MODULE__{
          kind: String.t(),
          metadata: map(),
          spec: map()
        }

  @kind_pinned "CapabilityProfile"

  # g24_9 — refuser les server-tools natifs Anthropic : ils tournent côté serveur, PAS dans le pod → le sandbox bwrap ne les contient pas par construction.
  # Entrées strict = égalité, entrées prefix = `String.starts_with?/2`.
  @disallowed_minimum_strict ~w(web_search web_fetch code_execution bash_code_execution text_editor_code_execution)
  @disallowed_minimum_prefix ~w(tool_search_)

  @containment_enum ~w(bwrap none)
  @lifetime_scope_enum ~w(one-shot pipe run forever)

  # Fast-path guard for top-level reserved keys. `metadata.containment`
  # and `metadata.name` are also reserved — enforced by the JSON schema
  # `priv/schema/modop-profile.json` (`not/anyOf` clause). `kind` reste
  # réservé (il différencie cap-profile vs modop côté merge) ; `apiVersion`
  # n'est PAS réservé (champ inexistant — versioning par le code).
  @reserved_modop_keys ~w(kind)

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
         :ok <- validate_against_schema(raw, :cap_profile) do
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
         :ok <- validate_against_schema(base, :cap_profile),
         {:ok, modops} <- read_modops(modop_set),
         merged <- Enum.reduce(modops, base, &deep_merge_last_wins(&2, &1)),
         :ok <- validate_against_schema(merged, :cap_profile) do
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
    # Pas de check apiVersion (l'ancien g24_2) : le champ apiVersion n'existe pas.
    violations =
      [
        {:g24_1, &check_containment/1},
        {:g24_3, &check_kind/1},
        {:g24_4, &check_lifetime_scope/1},
        {:g24_6, &check_modop_incompatible/1},
        {:g24_8, &check_metadata_name/1},
        {:g24_9_strict, &check_disallowed_strict/1},
        {:g24_9_prefix, &check_disallowed_prefix/1},
        {:g24_10, &check_boot_at_start_forever/1},
        {:g24_11, &check_subagent_template_one_shot/1},
        {:g24_12, &check_host_native_containment/1},
        {:g24_14, &check_monk_registry_pairing/1}
      ]
      |> Enum.reject(fn {_code, fun} -> fun.(profile) == :ok end)
      |> Enum.map(fn {code, _fun} -> code end)

    case violations do
      [] -> :ok
      list -> {:error, list}
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
                 :ok <- validate_modop_keys(raw),
                 :ok <- validate_against_schema(raw, :modop) do
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
  # Schema validation
  # ============================================================

  defp validate_against_schema(map, kind) do
    case load_schema(kind) do
      {:ok, schema} ->
        case ExJsonSchema.Validator.validate(schema, map) do
          :ok ->
            :ok

          {:error, _errors} ->
            case kind do
              :cap_profile -> {:error, :invalid_schema}
              :modop -> {:error, :invalid_modop}
            end
        end

      {:error, :schema_unavailable} = err ->
        err
    end
  end

  defp load_schema(:cap_profile), do: load_schema_file("cap-profile-v2.5.json")
  defp load_schema(:modop), do: load_schema_file("modop-profile.json")

  # Schema priv IMMUABLE : read+decode+resolve une fois, caché en `:persistent_term`
  # keyé par le path RÉSOLU (les overrides test de `schema_dir/0` ont leur entrée). Lazy-init,
  # erreurs non-cachées.
  defp load_schema_file(name) do
    path = Path.join(schema_dir(), name)
    key = {__MODULE__, :schema, path}

    case :persistent_term.get(key, :miss) do
      :miss ->
        case read_schema_file(path) do
          {:ok, _schema} = ok ->
            :persistent_term.put(key, ok)
            ok

          err ->
            err
        end

      cached ->
        cached
    end
  end

  defp read_schema_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content),
         {:ok, schema} <- safe_resolve(decoded) do
      {:ok, schema}
    else
      {:error, reason} ->
        Logger.warning("schema unavailable: #{inspect(reason)} at #{path}")
        {:error, :schema_unavailable}
    end
  end

  defp safe_resolve(decoded) do
    {:ok, ExJsonSchema.Schema.resolve(decoded)}
  rescue
    e -> {:error, {:schema_resolve_error, Exception.message(e)}}
  end

  defp schema_dir do
    case Application.get_env(:fleet_cap_profile, :schema_dir) do
      nil -> Path.join(to_string(:code.priv_dir(:fleet_cap_profile)), "schema")
      dir -> dir
    end
  end

  defp validate_modop_keys(map) do
    case Enum.find(@reserved_modop_keys, &Map.has_key?(map, &1)) do
      nil -> :ok
      _key -> {:error, :invalid_modop}
    end
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
  lecteurs (spawner/stage_runner/sp_builder/pod) — sinon défauts incohérents. `default` par
  défaut `"one-shot"` (le défaut canon) ; les lecteurs qui veulent distinguer l'absence
  (ex. mandate_guard) passent `nil`.
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
  Accesseur canon du `mandate_kind` (`spec.mandate_kind`, schéma v2.5). Dual D'ENTRÉE de
  `deliverable_mode` (sortie) : il déclare la **forme du mandat** que le rôle reçoit, par catalogue
  et PAS par nom magique de rôle.

    * `"worker"` (défaut) — le mandat est une instruction exécutable (corps de l'issue) : le rôle
      AGIT (engineer, architect…).
    * `"judge"` — le rôle JUGE : il reçoit un `GateBrief` structurellement **désamorcé** (contexte + livrable +
      contrat de verdict, AUCUNE instruction exécutable — sinon le juge exécuterait le body). Le gatekeeper le déclare.

  `default` `"worker"` est **fail-safe** : un profil sans champ reçoit un mandat exécutable (le cas
  ultra-majoritaire) ; jamais l'inverse (un worker désamorcé par erreur ne ferait rien). Un rôle
  juge DOIT déclarer `judge` explicitement — la judge-ness est une propriété de sécurité (rendue
  structurellement vraie, jamais inférée).
  """
  @spec mandate_kind(t(), term()) :: String.t() | term()
  def mandate_kind(%__MODULE__{spec: spec}, default \\ "worker") do
    get_in(spec, ["mandate_kind"]) || default
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

  # ============================================================
  # G24 invariants (one function per check)
  # ============================================================

  defp check_containment(%__MODULE__{metadata: meta}) do
    if Map.get(meta, "containment") in @containment_enum, do: :ok, else: :error
  end

  defp check_kind(%__MODULE__{kind: k}) do
    if k == @kind_pinned, do: :ok, else: :error
  end

  defp check_lifetime_scope(%__MODULE__{spec: spec}) do
    # Canon : lifetime_scope est nesté sous `spec.invocation` (schema
    # cap-profile-v2.5.json + cap-profiles canon), pas au niveau de `spec` —
    # lire `spec.lifetime_scope` directement raterait la valeur.
    if get_in(spec, ["invocation", "lifetime_scope"]) in @lifetime_scope_enum,
      do: :ok,
      else: :error
  end

  # Pas de check `git_ops_denied` (l'ancien g24_5) : les workers PEUVENT
  # push si le cap-profile l'autorise via `allowedTools` claude CLI.
  # L'invariant qui exigeait `"push"` dans `git_ops_denied` serait donc
  # obsolète. Le mécanisme générique catalogue → disallowedTools claude CLI
  # (via `with_resolved_disallowed_tools/1` + baseline `_baseline-git-denied.yaml`)
  # est le successeur : il interdit universellement les patterns destructeurs
  # (`push --force`, `reset --hard`, `--no-verify`, etc.) sans interdire
  # `push` en bloc.

  defp check_modop_incompatible(%__MODULE__{spec: spec}) do
    # `modop_set` est une MAP (schéma v2.5 : default/optional/incompatible),
    # pas une liste. Les paires incompatibles sont sous `spec.modop_set.incompatible` ;
    # les modops ACTIFS = `default` ++ `optional`. Ne PAS lire `spec.modop_incompatible`
    # (clé inexistante → toujours []) ni traiter `spec.modop_set` comme une liste,
    # sinon l'invariant ne tire jamais.
    modop_set = Map.get(spec, "modop_set", %{})

    # modop_set canon = MAP (default/optional/incompatible). Un profil legacy/vide peut le porter
    # en LISTE (`[]`) → `Map.get` crasherait (BadMapError). On traite la forme non-map comme « aucune
    # paire incompatible déclarée » → pas de conflit, pas de crash au boundary spawn (le mauvais
    # type est rendu inoffensif, pas rattrapé par un rescue).
    {pairs, active} =
      if is_map(modop_set) do
        {Map.get(modop_set, "incompatible", []),
         MapSet.new(Map.get(modop_set, "default", []) ++ Map.get(modop_set, "optional", []))}
      else
        {[], MapSet.new()}
      end

    conflict? =
      Enum.any?(pairs, fn pair ->
        case pair do
          [a, b] -> MapSet.member?(active, a) and MapSet.member?(active, b)
          _ -> false
        end
      end)

    if conflict?, do: :error, else: :ok
  end

  # Pas de check budget (l'ancien g24_7) : pas d'API = pas de budget. Le
  # timeout de réponse (jadis mal nommé budget.maxDurationSec) est désormais
  # un default codé par lifetime_scope dans
  # `Fleet.Spawner.Pod.monitor_timeout_ms/1` ; un override par cap-profile
  # (e.g. `spec.timeouts.response_sec`) est accepté optionnel mais
  # non-requis.

  defp check_metadata_name(%__MODULE__{metadata: meta}) do
    case Map.get(meta, "name") do
      name when is_binary(name) and byte_size(name) > 0 -> :ok
      _ -> :error
    end
  end

  defp check_disallowed_strict(%__MODULE__{spec: spec}) do
    disallowed = get_in(spec, ["scope", "disallowedTools"]) || []
    if Enum.all?(@disallowed_minimum_strict, &(&1 in disallowed)), do: :ok, else: :error
  end

  defp check_disallowed_prefix(%__MODULE__{spec: spec}) do
    disallowed = get_in(spec, ["scope", "disallowedTools"]) || []

    prefix_ok =
      Enum.all?(@disallowed_minimum_prefix, fn prefix ->
        Enum.any?(disallowed, &String.starts_with?(&1, prefix))
      end)

    if prefix_ok, do: :ok, else: :error
  end

  # ------------------------------------------------------------
  # G24-10..14 — extensions v2.5
  #
  # Clés/valeurs STRING : le struct est stringifié en profondeur
  # (`to_struct`). Les valeurs comparées sont donc des strings, pas des
  # atomes (`"forever"`, `"one-shot"` avec tiret, `"none"`) — comparer à un
  # atome `:forever` raterait toujours.
  # ------------------------------------------------------------

  # G24-10 : boot_at_start: true ⟹ lifetime_scope: forever.
  # Doublonne l'`allOf` JSON-schema (belt-and-suspenders, atome d'erreur verbeux).
  defp check_boot_at_start_forever(%__MODULE__{spec: spec}) do
    if get_in(spec, ["invocation", "boot_at_start"]) == true and
         get_in(spec, ["invocation", "lifetime_scope"]) != "forever" do
      :error
    else
      :ok
    end
  end

  # G24-11 : subagent_template non-vide ⟹ lifetime_scope: one-shot.
  # `subagent_template` (invocation) implique un dispatch one-shot ; distinct
  # de `knowledge.sp_template` (template SP d'un pod permanent monk/archivist)
  # qui n'est PAS contraint ici. nil ou "" = pas de template → pas de contrainte
  # (cohérent `minLength: 1` du schéma).
  defp check_subagent_template_one_shot(%__MODULE__{spec: spec}) do
    template = get_in(spec, ["invocation", "subagent_template"])
    scope = get_in(spec, ["invocation", "lifetime_scope"])

    if is_binary(template) and template != "" and scope != "one-shot" do
      :error
    else
      :ok
    end
  end

  # G24-12 : host_native: true ⟹ metadata.containment: none.
  # `containment` vit dans `metadata` (pas `spec`). Pas de clause `system_user` :
  # ce champ n'existe pas au schéma v2.5. Aligné sur l'`allOf` JSON
  # (containment seul).
  defp check_host_native_containment(%__MODULE__{spec: spec, metadata: meta}) do
    if get_in(spec, ["invocation", "host_native"]) == true and
         Map.get(meta, "containment") != "none" do
      :error
    else
      :ok
    end
  end

  # G24-14 : pairing monk_registry ⟺ monk_instance (both-or-neither).
  # Part PURE et structurelle (non portée par le JSON-schema, qui déclare
  # les deux indépendamment nullable). L'existence FS du registry + le
  # lookup de l'instance sont I/O ⟹ load-time (`compose/2`), pas ici.
  defp check_monk_registry_pairing(%__MODULE__{spec: spec}) do
    registry = get_in(spec, ["knowledge", "monk_registry"])
    instance = get_in(spec, ["knowledge", "monk_instance"])

    case {is_nil(registry), is_nil(instance)} do
      {true, true} -> :ok
      {false, false} -> :ok
      _ -> :error
    end
  end
end

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
  keys forbidden, mitigates the "containment override by modop" finding
  from PoC-11).

  Composition is deterministic: deep-merge last-wins in declared order,
  canonical JSON encoding (recursive key sort), `:crypto` sha256.
  """

  @behaviour Fleet.CapProfile.Loader

  require Logger

  # R0.8-brick3 : `api_version` field retiré (cf. feedback "pas d'apiVersion
  # dans YAML LCARS" — versioning par le code v2 release, pas champ embarqué).
  defstruct [:kind, :metadata, :spec]

  @type t :: %__MODULE__{
          kind: String.t(),
          metadata: map(),
          spec: map()
        }

  @kind_pinned "CapabilityProfile"

  # G24-9 (F-CONT-RISK) — server tools natifs Anthropic must be denied.
  # Strict entries match by equality, prefix entries by `String.starts_with?/2`.
  @disallowed_minimum_strict ~w(web_search web_fetch code_execution bash_code_execution text_editor_code_execution)
  @disallowed_minimum_prefix ~w(tool_search_)

  @containment_enum ~w(bwrap none)
  @lifetime_scope_enum ~w(one-shot pipe run forever)

  # Fast-path guard for top-level reserved keys. `metadata.containment`
  # and `metadata.name` are also reserved — enforced by the JSON schema
  # `priv/schema/modop-profile.json` (`not/anyOf` clause). R0.8-brick3 :
  # `apiVersion` retiré ; kind reste réservé (différenciation cap-profile
  # vs modop côté merge).
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
  de modops. Deep-merge last-wins, ordre déclaré = précédence (PoC-16).

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
  (canon cap-profile v2.5 + F-CONT-RISK gate). Fonction pure : aucune
  lecture de process ni de FS (cf. moduledoc) — même struct ⇒ même verdict.

  ## Invariants implémentés
    * Structuraux PROMUS chantier 1 : `:g24_1` (containment), `:g24_3`
      (kind), `:g24_4` (lifetime_scope enum), `:g24_6` (modop incompatible),
      `:g24_8` (metadata.name), `:g24_9_strict`/`:g24_9_prefix` (F-CONT-RISK
      disallowedTools minimum).
    * Belt-and-suspenders v2.5 (BL-022, doublonnent le JSON-schema `allOf`
      pour un atome verbeux côté Elixir) : `:g24_10` (boot_at_start ⟹
      forever), `:g24_11` (subagent_template ⟹ one-shot), `:g24_12`
      (host_native ⟹ containment none).
    * Couverture NON portée par le schéma : `:g24_14` (pairing
      monk_registry ⟺ monk_instance — both-or-neither).

  ## Hors `validate/1` (réconciliation BL-022 ↔ BL-006, justifiée)
    * **G24-13** (`mcp_channels` non-vide ⟹ `Fleet.MCP.Server` vivant) :
      check de **liveness runtime**, donc impur (non-déterministe) — viole
      le contrat « pure data transformer ». Concern de spawn-time, pas un
      invariant statique du profil. NON implémenté ici (sp-monde-invoqué :
      la liveness est bornée au boundary de spawn, pas dans le validateur).
    * **G24-12 `system_user` privilégié** : le pseudo-code DN l'exigeait
      mais `system_user` n'existe pas au schéma v2.5 (BL-006 F-6 ;
      G24-12 réel = `containment: none` seul, aligné sur l'`allOf` JSON).
    * **G24-14 existence FS du registry + lookup `monk_instance`** : I/O,
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
    # R0.8-brick3 : G24-2 (check_api_version) retiré — apiVersion n'existe plus.
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
  invalide. audit elixir #3 : la baseline est doctrinalement "intangible"
  — un fail-open silencieux (retour `[]`) désactiverait la denylist
  universelle sans alerter, contradictoire avec l'intention. Fail-closed
  cohérent avec la doctrine. Le caller (`pod.ex do_allocate`) catch via
  `rescue` et transitionne `:failed` proprement (Vulcan #5 préservé).

  Pure modulo I/O fichier ; pas de cache (lu une fois par résolution cap-
  profile, fréquence faible).
  """
  @spec baseline_git_ops_denied_patterns() :: [String.t()]
  def baseline_git_ops_denied_patterns do
    load_baseline_git_ops_denied!()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&"Bash(git #{&1}:*)")
  end

  # F021 — baseline priv IMMUABLE : read+parse une fois, caché en `:persistent_term`
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
  Returns the canonical JSON sha256 (lowercase hex) of a composed map
  or struct. Used by callers to assert deterministic composition
  (PoC-16 pattern). Underlying map iteration order is irrelevant — the
  canonical encoder sorts keys recursively before encoding.
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

  defp read_role_yaml(role) do
    candidates = [
      Path.join(root_dir(), "#{role}.yaml"),
      Path.join([root_dir(), "archivistes", "#{role}.yaml"])
    ]

    case Enum.find(candidates, &File.exists?/1) do
      nil -> {:error, :not_found}
      path -> decode_yaml(path)
    end
  end

  defp read_modops(modop_set) do
    result =
      Enum.reduce_while(modop_set, {:ok, []}, fn name, {:ok, acc} ->
        path = Path.join([root_dir(), "modop", name, "profile.yaml"])

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
  se désaccordent (#582, Fable F110/F111).
  """
  @spec root_dir() :: String.t()
  def root_dir do
    # I-CBC : un :root_dir explicitement nil (ex. fuite d'env cross-test en
    # umbrella) ne doit JAMAIS atteindre Path.join → coalesce vers le défaut.
    Application.get_env(:fleet_cap_profile, :root_dir) || "cap-profiles"
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

  # F022 — schema priv IMMUABLE : read+decode+resolve une fois, caché en `:persistent_term`
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
  schéma v2.5). Rework #4 : source unique — l'extraction était ré-implémentée dans
  spawner/stage_runner/sp_builder/pod avec des défauts incohérents. `default` par
  défaut `"one-shot"` (le défaut canon) ; les lecteurs qui veulent distinguer
  l'absence (ex. mandate_guard) passent `nil`.
  """
  @spec lifetime_scope(t(), term()) :: String.t() | term()
  def lifetime_scope(%__MODULE__{spec: spec}, default \\ "one-shot") do
    get_in(spec, ["invocation", "lifetime_scope"]) || default
  end

  @doc """
  Accesseur canon du `deliverable_mode` (`spec.deliverable_mode`, schéma v2.5, modèle O5). Source
  unique — la sélection du mode de publication (`Fleet.Pipeline.Deliverable.publish/1`) se lit ICI,
  pas ré-implémentée chez les lecteurs. `default` `"payload"` (le défaut canon, back-compat PASSE-7 :
  un profil sans champ = legacy le-système-écrit-le-payload). Les code-rôles déclarent `git_native`.
  """
  @spec deliverable_mode(t(), term()) :: String.t() | term()
  def deliverable_mode(%__MODULE__{spec: spec}, default \\ "payload") do
    get_in(spec, ["deliverable_mode"]) || default
  end

  @doc """
  Accesseur canon du `mandate_kind` (`spec.mandate_kind`, schéma v2.5). Dual D'ENTRÉE de
  `deliverable_mode` (sortie) : il déclare la **forme du mandat** que le rôle reçoit, par catalogue
  et PAS par nom magique (F077, `differentiation-par-catalogue`).

    * `"worker"` (défaut) — le mandat est une instruction exécutable (corps de l'issue) : le rôle
      AGIT (engineer, architect…).
    * `"judge"` — le rôle JUGE : il reçoit un `GateBrief` I-CBC **désamorcé** (contexte + livrable +
      contrat de verdict, AUCUNE instruction exécutable — bug PASSE-9). Le gatekeeper le déclare.

  `default` `"worker"` est **fail-safe** : un profil sans champ reçoit un mandat exécutable (le cas
  ultra-majoritaire) ; jamais l'inverse (un worker désamorcé par erreur ne ferait rien). Un rôle
  juge DOIT déclarer `judge` explicitement — la judge-ness est une propriété de sécurité (I-CBC),
  pas une inférence.
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

  # Rework #1 (axe « contrôle côté producteur ») : `metadata`/`spec` sont
  # garantis à **clés STRING en profondeur**, ici à la production (boundary
  # unique `to_struct`). Les lecteurs (ProjectBootstrap, sp_builder, spawner)
  # accèdent en clés string SANS double-lookup atom|string défensif — la forme
  # incohérente devient irreprésentable (I-CBC). Les structs (DateTime…) et
  # scalaires passent tels quels ; seules les CLÉS de map sont stringifiées.
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
    # Canon : lifetime_scope nesté dans spec.invocation (schema
    # cap-profile-v2.5.json + 7 cap-profiles 05_data-canon). Le code
    # lisait spec-level (forme pré-alignement schema) → aligné canon.
    if get_in(spec, ["invocation", "lifetime_scope"]) in @lifetime_scope_enum,
      do: :ok,
      else: :error
  end

  # G24-5 (check_git_ops_denied) retiré : Face 2 doctrine (commit 4e0b3b3c)
  # a tranché que les workers PEUVENT push si le cap-profile l'autorise via
  # `allowedTools` claude CLI. L'invariant qui exigeait `"push"` dans
  # `git_ops_denied` est obsolète. Le mécanisme générique catalogue →
  # disallowedTools claude CLI (via `with_resolved_disallowed_tools/1` +
  # baseline `_baseline-git-denied.yaml`) est le successeur : interdit
  # universellement les patterns destructeurs (`push --force`, `reset --hard`,
  # `--no-verify`, etc.) sans interdire `push` en bloc.

  defp check_modop_incompatible(%__MODULE__{spec: spec}) do
    # R13 : `modop_set` est une MAP (schéma v2.5 : default/optional/incompatible),
    # pas une liste. Les paires incompatibles sont sous `spec.modop_set.incompatible` ;
    # les modops ACTIFS = `default` ++ `optional`. L'ancien code lisait
    # `spec.modop_incompatible` (clé inexistante → toujours []) et traitait
    # `spec.modop_set` comme une liste → l'invariant ne tirait jamais.
    modop_set = Map.get(spec, "modop_set", %{})

    # modop_set canon = MAP (default/optional/incompatible). Un profil legacy/vide peut
    # le porter en LISTE (`[]`) → `Map.get` crasherait (BadMapError — jamais vu car
    # validate/1 n'était appelée qu'en test, CAP-D1). I-CBC : forme non-map = aucune
    # paire incompatible déclarée → pas de conflit, pas de crash au boundary spawn.
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

  # R0.8-brick4 : G24-7 (check_budget) retiré. Pas d'API = pas de budget
  # (cf. feedback "Pas de budget dans cap-profiles"). Le timeout de réponse
  # (auparavant mal nommé budget.maxDurationSec) est désormais un default
  # codé par lifetime_scope dans Fleet.Spawner.Pod.monitor_timeout_ms/1 ;
  # un override par cap-profile (e.g. `spec.timeouts.response_sec`) est
  # accepté optionnel mais non-requis.

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
  # G24-10..14 — extensions v2.5 (BL-022)
  #
  # Clés/valeurs STRING : le struct est stringifié en profondeur
  # (`to_struct` Rework #1). Le pseudo-code DN `fleet_cap_profile.md`
  # (atomes `:invocation`/`:forever`/`:one_shot`) le précède — il est
  # transposé string ici (`"forever"`, `"one-shot"` tiret, `"none"`).
  # ------------------------------------------------------------

  # G24-10 : boot_at_start: true ⟹ lifetime_scope: forever.
  # Doublonne l'`allOf` JSON-schema (belt-and-suspenders, atome verbeux).
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
  # de `knowledge.sp_template` (ADR #565, pod permanent monk/archivist) qui
  # n'est PAS contraint ici. nil ou "" = pas de template → pas de contrainte
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

  # G24-12 : host_native: true ⟹ metadata.containment: none (D-01).
  # `containment` vit dans `metadata` (pas `spec`). La clause `system_user`
  # du pseudo-code DN est ABANDONNÉE : champ inexistant au schéma v2.5
  # (BL-006 F-6). Aligné sur l'`allOf` JSON (containment seul).
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

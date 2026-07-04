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
  # `load`/`compose` y délèguent (via `Catalog.read_modops` aussi) ; pas de cycle
  # (Schema n'appelle rien ici).
  alias Fleet.CapProfile.Schema

  # Cluster FS du catalogue (résolution par metadata.name, scan YAML, confinement Slug).
  # `load`/`compose` appellent `Catalog.read_role`/`Catalog.read_modops` ; `list/1` et
  # `root_dir/0` (consommés hors-app) y délèguent. Pas de cycle : Catalog est en AMONT
  # (il dépend de Schema, pas du cœur).
  alias Fleet.CapProfile.Catalog

  # Cluster de résolution write-time de `spec.scope.disallowedTools` (baseline
  # git-denied ∪ profil). Les trois helpers publics ci-dessous y délèguent ; pas
  # de cycle (DisallowedTools dépend du struct, pas de l'API cœur).
  alias Fleet.CapProfile.DisallowedTools

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

  # Mode de containment par défaut = pod SANDBOXÉ. SOURCE UNIQUE du littéral : un trou de config
  # (clé `metadata.containment` absente) présume TOUJOURS le mode confiné, jamais l'hôte. Lu par
  # `containment/1` (défaut) et `bwrap?/1` (prédicat), et référencé cross-app par l'admission API.
  @default_containment "bwrap"

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
    with {:ok, raw} <- Catalog.read_role(role),
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
    with {:ok, base} <- Catalog.read_role(role),
         :ok <- Schema.validate(base, :cap_profile),
         {:ok, modops} <- Catalog.read_modops(modop_set),
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
  Traduit `spec.scope.git_ops_denied` en patterns `disallowedTools` claude CLI
  `Bash(git <entrée>:*)`. **Délègue** au cluster de résolution
  `Fleet.CapProfile.DisallowedTools`. Public (tests + interne).
  """
  @spec git_ops_denied_patterns(t()) :: [String.t()]
  defdelegate git_ops_denied_patterns(profile), to: DisallowedTools

  @doc """
  Retourne un `%CapProfile{}` dont `spec.scope.disallowedTools` fusionne (uniq,
  ordre préservé : existants, baseline universel intangible, patterns du profil).
  Idempotent. Point d'application : `Fleet.Spawner.Pod.do_allocate/1` (écriture
  `.cap-profile.json` du pod). **Public + consommé par pod.ex** — **délègue** à
  `Fleet.CapProfile.DisallowedTools.with_resolved/1` (l'API portée ici ne bouge pas).
  """
  @spec with_resolved_disallowed_tools(t()) :: t()
  defdelegate with_resolved_disallowed_tools(profile), to: DisallowedTools, as: :with_resolved

  @doc """
  Patterns `disallowedTools` du baseline universel intangible
  (`priv/canon/cap-profiles/_baseline-git-denied.yaml`) — **raise** fail-closed si
  le baseline est absent/corrompu. **Délègue** à
  `Fleet.CapProfile.DisallowedTools.baseline_patterns/0`. Public (tests + interne).
  """
  @spec baseline_git_ops_denied_patterns() :: [String.t()]
  defdelegate baseline_git_ops_denied_patterns(), to: DisallowedTools, as: :baseline_patterns

  @doc """
  Retourne un `%CapProfile{}` dont `spec.project` est REMPLACÉ par le projet effectif donné (map de
  clés string, même forme que le `spec.project` du YAML : `repo_path`, `repo`, `remote`…).

  Un pod-projet peut recevoir son projet du BRIEF (dispatch issue→repo, `opts[:project]`) plutôt que
  du cap-profile statique : les lecteurs de `spec.project` (ex. `Fleet.ProjectBootstrap.Phase.Clone`)
  reçoivent alors ce cap-profile EFFECTIF. **Source UNIQUE** de cette substitution — les call-sites
  (`Fleet.Spawner.Pod.Scaffold.maybe_bootstrap_project_workspace`, le reprovision workspace de
  `Fleet.Spawner.Pod`) ne re-bricolent pas la map `spec` à la main. Pure (rend un nouveau struct).
  """
  @spec with_project(t(), map()) :: t()
  def with_project(%__MODULE__{spec: spec} = cap, project) when is_map(project),
    do: %{cap | spec: Map.put(spec, "project", project)}

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
    do: Map.get(meta, "containment") || Map.get(meta, :containment) || @default_containment

  def containment(%__MODULE__{}), do: @default_containment

  @doc """
  Le mode de containment par défaut (`"bwrap"`, pod sandboxé) — SOURCE UNIQUE du littéral, référencée
  par les lecteurs cross-app plutôt que de le retaper.
  """
  @spec default_containment() :: String.t()
  def default_containment, do: @default_containment

  @doc """
  Le profil est-il en containment sandboxé bwrap (le défaut) ? `false` = host-native (`"none"`, le
  pod tourne sur l'hôte *as* l'humain). Prédicat unique pour les gardes host-native (ex. admission API).
  """
  @spec bwrap?(t()) :: boolean()
  def bwrap?(%__MODULE__{} = cap), do: containment(cap) == @default_containment

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
  # Catalogue FS (délégué)
  # ============================================================

  @doc """
  Liste les NOMS (`metadata.name`) des cap-profiles du catalogue (`dir`, défaut `root_dir/0`).
  **Délègue** au cluster FS `Fleet.CapProfile.Catalog`. Public + **consommé hors-app**
  (`Fleet.Spawner.PermanentBoot` énumère, `Fleet.Observation.Deck` liste le dashboard) →
  l'API portée ici ne bouge pas.
  """
  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  defdelegate list(), to: Catalog
  defdelegate list(dir), to: Catalog

  @doc """
  Racine du catalogue cap-profiles (`<root_dir>/<role>.yaml`). **Source UNIQUE** : tout
  énumérateur (ex. `Fleet.Spawner.PermanentBoot`) DOIT scanner ce dir, sinon enum et load
  se désaccordent. **Délègue** à `Fleet.CapProfile.Catalog.root_dir/0` (consommé hors-app).
  """
  @spec root_dir() :: String.t()
  defdelegate root_dir(), to: Catalog

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
  la sélection du mode de publication (`Fleet.Workflow.Deliverable.publish/1`) se lit ICI, pas
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

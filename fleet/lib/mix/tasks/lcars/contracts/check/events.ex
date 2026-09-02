defmodule Mix.Tasks.Lcars.Contracts.Check.Events do
  # Z4 — classe dans la boundary de son sujet, comme la tache qui l'utilise.
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  Les murs de la voie des evenements : ce qui est emis, ce qui est consomme, et les vocabulaires
  fermes que les deux bouts doivent partager.

  Un evenement n'a pas de destinataire declare. Un consommateur reste sur une forme abandonnee et il
  ne matche plus RIEN — pas d'erreur, pas de log, juste un abonne qui ne reagit plus. Une cle
  d'evenement qui existe d'un cote et pas de l'autre produit la meme chose. C'est la classe de panne
  la plus discrete du runtime, et ces murs sont ce qui la rend visible avant l'execution.

  ⚠ MEME REGLE POUR LES VOCABULAIRES FERMES (severites de findings, genres d'escalade, types
  visuels) : ils sont enumeres a un endroit et lus a un autre. Un cas ajoute d'un seul cote ne
  plante pas — il tombe dans une clause par defaut, ou il n'est jamais atteint. Ces murs comparent
  les ENSEMBLES, jamais un appel.
  """

  alias Mix.Tasks.Lcars.Contracts.Check.Support

  import Mix.Tasks.Lcars.Contracts.Check.Support

  # ── Implemented checks ───────────────────────────────────────────────

  # Event consumers must match `%Fleet.Event{}`, never the legacy tuple
  # `{atom, %{"event_type" => ...}}` — a consumer left on the tuple is
  # dead against the canonical struct (it matches nothing anymore) and the drift is silent.
  # This check measures the real CODE of the targets below and flags any residual
  # `"event_type" =>` read.
  # 9th instance of the B family (residue_check), migrated in the shared-combinator factorization. The `confirm` = the
  # pattern itself post-strip: an `"event_type" =>` mention in a COMMENT (doc of the legacy-tuple
  # removal) does not count as a violation (otherwise the gate would flag its own documentation).
  # SCOPE: a GLOBAL residue sweep over lib/ — the id's "canon" covers every consumer, matching
  # what the name claims (it long scanned only api/ws.ex, the last migrant).
  @doc false
  @spec check_event_consumers_canon(String.t()) :: Support.result()
  def check_event_consumers_canon(root) do
    # The check's NAME claims the canon for ALL consumers; it long grepped ws.ex alone (the last
    # migrant), leaving the guarantee narrower than its label. The residue scan now covers
    # every source under lib/ — a legacy `"event_type"` tuple REINTRODUCED anywhere fails the gate,
    # not just in the one file that once carried it.
    residue_check(root, %{
      id: "event.consumers.canon",
      remediation:
        "migrate the flagged consumer(s) off the legacy `event_type` tuple to `%Fleet.Event{}` matching",
      files:
        Path.wildcard(Path.join(root, "lib/**/*.ex"))
        |> Enum.map(&Path.relative_to(&1, root)),
      pattern: ~r/"event_type"\s*=>/,
      confirm: ~r/"event_type"\s*=>/,
      note: "a consumer on the legacy \"event_type\" tuple (canon = %Fleet.Event{} matching)"
    })
  end

  # The Loader must unwrap the v2.5 ENVELOPE (kind/metadata/spec.steps) into the single internal
  # FLAT form. There is NO v1: a flat/envelope-less YAML fails the v2.5 schema before `normalize`.
  # "v1/v2.5" = external envelope vs internal flat (same version, two shapes), NOT two versions.
  # Without the unwrap, a consumer reads `workflow_map["steps"]=nil` (steps live under spec.steps).
  @doc false
  @spec check_pipeline_v25_normalized(String.t()) :: Support.result()
  def check_pipeline_v25_normalized(root) do
    rel = "lib/fleet/workflow/loader.ex"
    loader = Path.join(root, rel)

    # Anti-hollow-green: matching `~r/normalize/i` over the WHOLE source would turn the rail green as soon as a
    # mere COMMENT contains "normalize", even without the code. So we match the real CODE CLAUSE
    # that unwraps `spec.steps` (the v2.5 normalization) AND its call, STRIPPING the comment from each
    # line (a commented-out `# defp normalize(...)` does not count).
    unwrap_clause? =
      loader
      |> grep_lines(~r/defp normalize\(%\{"spec"/)
      |> Enum.any?(fn {_l, line} -> Regex.match?(~r/defp normalize/, strip_comment(line)) end)

    called? =
      loader
      |> grep_lines(~r/normalize\(yaml\)/)
      |> Enum.any?(fn {_l, line} -> Regex.match?(~r/normalize\(yaml\)/, strip_comment(line)) end)

    ok? = unwrap_clause? and called?

    %{
      id: "pipeline.v25.normalized",
      remediation:
        "add the v2.5 `normalize` unwrap clause for spec.steps so a workflow_map consumer does not read steps=nil",
      status: if(ok?, do: :pass, else: :fail),
      evidence:
        cond do
          not unwrap_clause? ->
            [
              "#{rel}: `defp normalize(%{\"spec\" => %{\"steps\" => ...}})` clause (v2.5 unwrap) missing → a workflow_map consumer reads steps=nil"
            ]

          not called? ->
            ["#{rel}: `normalize(yaml)` never called at load → v2.5 envelope not unwrapped"]

          true ->
            []
        end,
      note:
        "Loader UNWRAPS spec.steps via the v2.5 CODE CLAUSE (`defp normalize(%{\"spec\"…})`) AND calls it at load — matches the code, not a comment (hardened anti-hollow-green)"
    }
  end

  # Every handler referenced in events.yaml must exist, otherwise the route is a
  # phantom handler tolerated silently.
  @doc false
  @spec check_events_handlers_exist(String.t()) :: Support.result()
  def check_events_handlers_exist(root) do
    yaml = Path.join(root, "priv/event_router/events.yaml")

    missing =
      case YamlElixir.read_from_file(yaml) do
        {:ok, %{"events" => events}} when is_map(events) ->
          events
          |> Map.values()
          |> List.flatten()
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()
          |> Enum.reject(&module_exists?/1)

        _ ->
          # HOLLOW-GREEN GUARD (R0-EVT-012): an ABSENT/invalid events.yaml used to yield `[]` → `:pass`
          # — the "every handler exists" check passing precisely when the registry it reads is GONE. An
          # unreadable registry is a broken deploy → FAIL, not a silent green.
          [
            "events.yaml absent or invalid at #{yaml} — handlers unverifiable (hollow-green guard)"
          ]
      end

    %{
      id: "events.handlers.exist",
      remediation:
        "remove the phantom handler ref(s) from events.yaml, or add the missing subscriber(s)",
      status: if(missing == [], do: :pass, else: :fail),
      evidence: Enum.map(missing, &"events.yaml → #{&1} (missing)"),
      note: "phantom handlers referenced in events.yaml (dispatch table vs direct subscribers)"
    }
  end

  # LA DEPENDANCE INVISIBLE DU FOURNISSEUR — nature de couture SANS PRECEDENT dans ce depot.
  #
  # `Reconciliation.@pulled_states [:assigned]` dit qu'un work-item `:pending` (enfile, jamais tire)
  # ne possede AUCUN verrou. Trois modules raisonnent sur cette regle sans jamais l'appeler : ils la
  # citent en commentaire. Le fournisseur, lui, ignorait qu'il portait une garantie pour eux — la
  # changer casse leur raisonnement en silence, et rien ne relie les quatre fichiers.
  #
  # Les cinq autres natures de couture se verifient entre deux ENSEMBLES qui s'ecrivent. Celle-ci
  # n'a rien a comparer : la dependance ne laisse aucune trace executable. La seule forme qui la
  # rende verifiable est que le fournisseur la DECLARE — d'ou `pulled_states_dependents/0`, une
  # valeur dont le seul lecteur est ce mur.
  #
  # DEUX SENS, et le second est celui qui coute : un dependant qui apparait sans etre declare
  # reintroduit exactement l'angle mort qu'on ferme.
  #
  # ## Preuve (mutations jouees a la pose, 2026-08-20)
  # (a) un dependant retire de la declaration -> ECHEC, fichier nomme cote « cite, non declare » ;
  # (b) un fichier declare qui ne cite plus rien -> ECHEC, nomme cote « declare, ne cite plus ».
  # Angle mort declare : la citation est un GREP sur `@pulled_states`. Un module qui raisonnerait
  # sur la regle sans la nommer resterait invisible — c'est le prix d'une dependance qui ne
  # s'execute pas, et le nommage est deja la discipline du depot.
  @doc false
  @spec check_pulled_states_declared(String.t()) :: Support.result()
  def check_pulled_states_declared(root) do
    rel = "lib/fleet/pilot/poller/reconciliation.ex"

    declared =
      root
      |> quoted!(rel)
      |> collect(fn
        {:@, _, [{:pulled_states_dependents, _, [list]}]} when is_list(list) -> list
        _ -> nil
      end)
      |> List.flatten()
      |> collect_strings()
      |> MapSet.new()

    citing =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(&String.contains?(File.read!(&1), "@pulled_states"))
      |> Enum.map(&Path.relative_to(&1, root))
      # Le fournisseur lui-meme, et L'ARBRE DU VERIFICATEUR : le gate LIT la regle, il n'en depend
      # pas. S'auto-compter ferait rougir le mur sur sa propre pose — mesure a la pose, 2026-08-20.
      #
      # ⚠ C'ETAIT UN CHEMIN EN DUR vers `lcars.contracts.check.ex`, et le decoupage du 2026-09-02 a
      # fait rougir ce mur : il avait demenage, et son exemption pointait son ancienne adresse. Une
      # liste de chemins en dur grossit a chaque coupe et rougit la fois ou on l'oublie — la REGLE
      # la remplace : ce qui vit dans l'arbre du verificateur LIT la regle, il n'en depend jamais.
      |> Enum.reject(&(&1 == rel or checker_source?(&1)))
      |> MapSet.new()

    cond do
      measured_nothing?(MapSet.to_list(declared)) ->
        broken_result(
          "reconciliation.pulled_states_declared",
          "@pulled_states_dependents in #{rel}"
        )

      measured_nothing?(MapSet.to_list(citing)) ->
        broken_result("reconciliation.pulled_states_declared", "files citing @pulled_states")

      true ->
        non_declares = citing |> MapSet.difference(declared) |> Enum.sort()
        fantomes = declared |> MapSet.difference(citing) |> Enum.sort()

        %{
          id: "reconciliation.pulled_states_declared",
          remediation:
            "`@pulled_states` porte une garantie pour des modules qui ne l'appellent pas — le " <>
              "fournisseur doit les nommer, sinon le changer casse leur raisonnement en silence",
          status: if(non_declares == [] and fantomes == [], do: :pass, else: :fail),
          evidence:
            Enum.map(non_declares, &"cite @pulled_states, NON declare: #{&1}") ++
              Enum.map(fantomes, &"declare, ne cite plus: #{&1}"),
          note: "provider declares the dependents of its ownership rule (nature 4)"
        }
    end
  end

  # L'ECHELLE DE SEVERITE, ECRITE DEUX FOIS.
  #
  # `FindingsWire.severities/0` porte l'ORDRE (du plus faible au plus fort) : le `block_at` d'une
  # carte s'y compare. `findings-v1.json` porte l'APPARTENANCE : ce qu'un juge a le droit d'ecrire.
  # Deux formes, un seul vocabulaire — et le `@doc` de la fonction affirme etre « the ONLY place
  # this order is written », ce qui est vrai de l'ORDRE et faux de l'ENSEMBLE.
  #
  # La paire est nee DANS le lot qui a paye le cas `"none"` : un juge avait ecrit `"none"` pour dire
  # « rien trouve », l'enum ne le portait pas, et toute sa charge est morte pour un mot. La lecon du
  # lot etait « tout ce qu'un juge peut ecrire doit etre accepte ou refuse lisiblement » ; le meme
  # lot a cree une seconde copie du meme vocabulaire, sans mur.
  #
  # Ce check compare les ENSEMBLES, jamais l'ordre : l'ordre n'existe que cote Elixir, et un enum
  # JSON n'en porte aucun. Une severite ajoutee d'un cote et pas de l'autre est refusee ici.
  #
  # ## Preuve (mutation jouee a la pose, 2026-08-20)
  # (a) Ajouter `"blocker"` a `severities/0` sans toucher le schema -> ECHEC, la severite est
  #     nommee absente des DEUX enums.
  # (b) Remplacer `"important"` par `"zzz"` dans le seul enum `severity_max` -> ECHEC, une absence
  #     et un surnombre nommes. La version qui ne lisait que l'enum par-finding restait verte.
  # Angle mort declare : `"none"` est ecrit ici, pas derive — aucun code Elixir ne le produit, il
  # naît du juge et ne vit que dans le schema. Un second sentinelle du meme genre serait invisible.
  # La valeur que le juge rend quand la mesure est faite et vide. Elle n'existe QUE dans le
  # schema — aucun code Elixir ne la produit — donc le mur la nomme ici plutot que de deviner.
  @severity_max_empty "none"

  @doc false
  @spec check_findings_severities_aligned(String.t()) :: Support.result()
  def check_findings_severities_aligned(root) do
    rel_ex = "lib/fleet/findings_wire.ex"
    rel_json = "priv/workflow/schema/findings-v1.json"

    from_code =
      root
      |> quoted!(rel_ex)
      |> collect(fn
        {:def, _, [{:severities, _, nil} | rest]} -> rest
        {:def, _, [{:severities, _, []} | rest]} -> rest
        _ -> nil
      end)
      |> List.flatten()
      |> collect_strings()
      |> MapSet.new()

    json =
      with {:ok, raw} <- File.read(Path.join(root, rel_json)),
           {:ok, decoded} <- Jason.decode(raw) do
        decoded
      else
        _ -> %{}
      end

    enum = fn path ->
      case get_in(json, path) do
        l when is_list(l) -> MapSet.new(l)
        _ -> MapSet.new()
      end
    end

    from_schema = enum.(["properties", "findings", "items", "properties", "severity", "enum"])

    # LE SECOND ENUM, ET CELUI OU L'INCIDENT A EU LIEU. `severity_max` n'est pas une redite de
    # `severity` : c'est l'operande que `Gates.Predicate` compare (`"severity_max != critical"`),
    # donc le seul des deux qu'une porte lise. Il porte une valeur de plus, `"none"` — la mesure
    # faite dont le resultat est vide, refusee au fil quand elle manquait. Le mur ne lisait que
    # l'enum par-finding : une severite ajoutee ici et pas la, ou l'inverse, passait au vert.
    max_expected = MapSet.put(from_code, @severity_max_empty)
    from_max = enum.(["properties", "severity_max", "enum"])

    cond do
      measured_nothing?(MapSet.to_list(from_code)) ->
        broken_result("findings.severities_aligned", "severities/0 in #{rel_ex}")

      measured_nothing?(MapSet.to_list(from_schema)) ->
        broken_result("findings.severities_aligned", "severity enum in #{rel_json}")

      measured_nothing?(MapSet.to_list(from_max)) ->
        broken_result("findings.severities_aligned", "severity_max enum in #{rel_json}")

      true ->
        code_only = from_code |> MapSet.difference(from_schema) |> Enum.sort()
        schema_only = from_schema |> MapSet.difference(from_code) |> Enum.sort()
        max_missing = max_expected |> MapSet.difference(from_max) |> Enum.sort()
        max_extra = from_max |> MapSet.difference(max_expected) |> Enum.sort()

        %{
          id: "findings.severities_aligned",
          remediation:
            "une severite ecrite d'un seul cote est soit refusee au fil (le juge perd sa charge " <>
              "entiere, cf. le cas `none`), soit acceptee et jamais comparee au `block_at`",
          status:
            if(code_only == [] and schema_only == [] and max_missing == [] and max_extra == [],
              do: :pass,
              else: :fail
            ),
          evidence:
            Enum.map(code_only, &"absente de l'enum severity: #{inspect(&1)}") ++
              Enum.map(schema_only, &"absente de severities/0: #{inspect(&1)}") ++
              Enum.map(max_missing, &"absente de l'enum severity_max: #{inspect(&1)}") ++
              Enum.map(max_extra, &"en trop dans severity_max: #{inspect(&1)}"),
          note:
            "findings-v1 severity vocabulary: severities/0 == enum severity, " <>
              "et == enum severity_max prive de #{inspect(@severity_max_empty)}"
        }
    end
  end

  # Les binaires litteraux d'un fragment d'AST — la liste rendue par une fonction, sans l'evaluer.
  defp collect_strings(ast) do
    collect(ast, fn
      s when is_binary(s) -> s
      _ -> nil
    end)
  end

  # LA TABLE DES KINDS D'ESCALADE, FERMEE DANS LES DEUX SENS.
  #
  # `Escalation.kind_describe/1` est une table CLOSE : un kind sans clause n'ouvre pas d'issue, il
  # leve un `FunctionClauseError`. C'est ce qui est arrive a `:awaits_arch_stuck` — emis par
  # `StepRunConsumer.drain_failed/4`, sans clause — et il a crashe exactement sur le chemin
  # « un ticket sort du pipeline en silence ». Le temoin du drain stubbait `escalate_fun`, donc il
  # ne pouvait pas le voir : une couverture de test ne dit rien d'une couture.
  #
  # L'autre sens coute moins cher mais ment autant : une clause sans producteur (`:pod_failed`,
  # 2026-08-20) se lit comme une garantie que quelque chose sait remonter ce cas. C'est le motif
  # « mensonge du registre » que `events.yaml` nomme deja pour ses propres cles.
  #
  # DEUX SOURCES DE PRODUCTION, et il faut les deux : les routes declaratives d'`events.yaml`
  # (`escalate_kind:`) et les sites de code, ou le kind est le PREMIER argument d'un appel a cinq
  # arguments dont l'appele nomme une escalade (`escalate`, `escalate_gated`, `escalate_or_signal`,
  # ou la couture homonyme). Le Catalog garde deja au boot qu'une route `immediate` PORTE un
  # `escalate_kind` ; il ne verifie pas que ce kind ait une clause.
  #
  # ## Preuve (mutations jouees a la pose, 2026-08-20)
  # (a) clause retiree pour un kind produit -> ECHEC, kind nomme cote « sans clause » ;
  # (b) clause ajoutee pour un kind que personne ne produit -> ECHEC, kind nomme cote « morte » ;
  # (c) `escalate_kind: :disk_full` pose chez un appelant de `record_or_escalate/4` -> ECHEC, kind
  #     nomme « emis SANS clause ». C'est la voie CANONIQUE, et la version precedente la manquait
  #     entierement : le kind ne passe pas en argument, il voyage dans les opts ;
  # (d) une clause morte gardee vivante par un COMMENTAIRE de `events.yaml` -> ECHEC. Le regex
  #     lisait le texte brut, donc une ligne d'historique suffisait a nier la mort d'une clause.
  # Angle mort declare : un kind construit dynamiquement (variable, interpolation) est invisible —
  # aucun n'existe aujourd'hui, et un mur precis vaut mieux qu'un mur qui devine.
  @doc false
  @spec check_escalation_kinds_closed(String.t()) :: Support.result()
  def check_escalation_kinds_closed(root) do
    rel = "lib/fleet/pilot/incident_registry/escalation.ex"

    declared =
      root
      |> quoted!(rel)
      |> collect(fn
        {:defp, _, [{:kind_describe, _, [k]} | _]} when is_atom(k) -> k
        _ -> nil
      end)
      |> MapSet.new()

    from_code =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn f ->
        f |> File.read!() |> Code.string_to_quoted!() |> escalated_kinds()
      end)
      |> MapSet.new()

    from_yaml =
      case File.read(Path.join(root, "priv/event_router/events.yaml")) do
        {:ok, y} ->
          # Les commentaires tombent AVANT la lecture : la version brute lisait le texte entier,
          # donc `# historique: on avait un jour escalate_kind: zzz_dead` suffisait a garder
          # vivante une clause que plus personne ne produit. Un mur qui lit un commentaire mesure
          # ce que quelqu'un a ECRIT, pas ce que le systeme EMET.
          ~r/escalate_kind:\s*([a-z_]+)/
          |> Regex.scan(y |> String.split("\n") |> Enum.map_join("\n", &strip_comment/1))
          |> Enum.map(fn [_, k] -> String.to_atom(k) end)
          |> MapSet.new()

        _ ->
          MapSet.new()
      end

    emitted = MapSet.union(from_code, from_yaml)

    sans_clause = emitted |> MapSet.difference(declared) |> Enum.sort()
    mortes = declared |> MapSet.difference(emitted) |> Enum.sort()

    cond do
      measured_nothing?(MapSet.to_list(declared)) ->
        broken_result("incident.kinds_closed", "defp kind_describe/1 in #{rel}")

      measured_nothing?(MapSet.to_list(emitted)) ->
        broken_result("incident.kinds_closed", "escalate_kind producers (events.yaml + lib/)")

      true ->
        %{
          id: "incident.kinds_closed",
          remediation:
            "tout kind emis doit avoir sa clause `kind_describe/1` (sinon l'escalade CRASHE au " <>
              "lieu d'ouvrir l'issue) et toute clause doit avoir un producteur (sinon la table " <>
              "annonce une remontee que personne ne declenche)",
          status: if(sans_clause == [] and mortes == [], do: :pass, else: :fail),
          evidence:
            Enum.map(sans_clause, &"emis SANS clause: #{inspect(&1)}") ++
              Enum.map(mortes, &"clause MORTE (aucun producteur): #{inspect(&1)}"),
          note: "escalation kinds: emitted set == kind_describe/1 clause set"
        }
    end
  end

  # Le kind d'une escalade : premier argument d'un appel a CINQ arguments dont l'appele nomme une
  # escalade. Couvre l'appel direct, la couture (`escalate.(…)`) et le relais local.
  defp escalated_kinds(ast) do
    collect(ast, fn
      # (1) le kind litteral en TETE d'un appel a cinq arguments dont l'appele nomme une escalade.
      {callee, _, [k | rest]} when is_atom(k) and length(rest) == 4 ->
        n = callee_name(callee)
        if n && String.contains?(Atom.to_string(n), "escalate"), do: k, else: nil

      # (2) `escalate_kind: :foo` dans n'importe quelle liste a mots-cles. C'EST LA VOIE
      #     CANONIQUE, et la version (1) seule la manquait entierement : l'API publique est
      #     `record_or_escalate/4`, qui ne prend PAS le kind en argument — il voyage dans ses
      #     `opts` jusqu'a `escalate/5` (`incident_registry.ex:84`). Un `escalate_kind: :disk_full`
      #     ecrit chez un appelant passait donc au vert et levait un `FunctionClauseError` a
      #     l'execution, exactement le crash que cette table close est censee rendre impossible.
      {:escalate_kind, k} when is_atom(k) and k not in [nil, true, false] ->
        k

      # (3) le DEFAUT du meme acces : `Keyword.get(opts, :escalate_kind, :recurrence)` emet
      #     `:recurrence` sans qu'aucun appelant ne l'ecrive nulle part.
      {{:., _, [{:__aliases__, _, [:Keyword]}, g]}, _, [_, :escalate_kind, d]}
      when g in [:get, :get_lazy] and is_atom(d) and d not in [nil, true, false] ->
        d

      _ ->
        nil
    end)
  end

  defp callee_name({:., _, [{n, _, _}]}) when is_atom(n), do: n
  defp callee_name({:., _, [_mod, n]}) when is_atom(n), do: n
  defp callee_name(n) when is_atom(n), do: n
  defp callee_name(_), do: nil

  # LE COUPLE `type_for_destination/1` <-> `visual_types/0` : l'un PRODUIT les types visuels, l'autre
  # les SEME sur chaque depot. Deux ensembles qui doivent rester egaux, et qui ont divergé pendant
  # SEIZE JOURS — `type:doc` seme et porte par personne, `type:workshop` porte et jamais seme, donc
  # cree paresseusement, gris et sans description.
  #
  # `visual_types/0` est desormais DERIVEE : elle mappe `type_for_destination/1` sur `@destinations`.
  # La derivation ferme la recopie ; ce mur ferme ce qu'elle laisse ouvert — qu'une clause ajoutee a
  # `type_for_destination/1` ait sa destination dans `@destinations`. Sans lui, un troisieme type
  # naitrait produit et jamais seme, exactement comme le deuxieme.
  #
  # ## Preuve (mutation jouee a la pose, 2026-08-20)
  # (a) Ajouter une clause `def type_for_destination("ops"), do: "type:ops"` sans toucher
  #     `@destinations` -> ECHEC, 3 clauses annoncees pour 2 destinations.
  # (b) Rendre `visual_types/0` a sa forme d'avant — `do: ["type:feature", "type:doc"]`, la recopie
  #     exacte qui a diverge seize jours -> ECHEC, la derivation manquante ET les deux litteraux
  #     nommes. La version qui comptait seulement clauses contre destinations restait verte : elle
  #     ne lisait jamais la fonction dont elle porte le nom.
  # Son angle mort, declare : il compte, il ne resout pas — deux clauses rendant le MEME type
  # passeraient pour deux destinations manquantes si l'une n'etait pas listee. Le cas n'existe pas
  # aujourd'hui et un compteur exact vaut mieux qu'un resolveur qui devine.
  @doc false
  @spec check_visual_types_derived(String.t()) :: Support.result()
  def check_visual_types_derived(root) do
    rel = "lib/fleet/labels.ex"
    ast = quoted!(root, rel)

    clauses =
      collect(ast, fn
        {:def, _, [{:type_for_destination, _, [_arg]} | _]} -> :clause
        _ -> nil
      end)

    destinations =
      collect(ast, fn
        {:@, _, [{:destinations, _, [list]}]} when is_list(list) -> length(list)
        _ -> nil
      end)

    # LE CORPS DE `visual_types/0`, ET C'EST LE POINT QUI MANQUAIT. Le mur comptait des clauses
    # contre des destinations et ne lisait JAMAIS la fonction dont il porte le nom : reecrire
    # `def visual_types, do: ["type:feature", "type:doc"]` — la recopie exacte qui a diverge
    # pendant seize jours — le laissait au vert. Un mur qui garde une DERIVATION doit constater
    # la derivation, pas ses deux operandes.
    body =
      collect(ast, fn
        {:def, _, [{:visual_types, _, a}, [do: b]]} when a in [nil, []] -> b
        _ -> nil
      end)

    cond do
      measured_nothing?(clauses) ->
        broken_result("labels.visual_types_derived", "def type_for_destination/1 in #{rel}")

      measured_nothing?(destinations) ->
        broken_result("labels.visual_types_derived", "@destinations in #{rel}")

      measured_nothing?(body) ->
        broken_result("labels.visual_types_derived", "def visual_types/0 in #{rel}")

      true ->
        n_clauses = length(clauses)
        n_dest = hd(destinations)
        b = hd(body)

        reads = fn name ->
          [] !=
            collect(b, fn
              {:@, _, [{^name, _, _}]} -> :ref
              {^name, _, _} -> :ref
              {:/, _, [{^name, _, _}, _]} -> :ref
              _ -> nil
            end)
        end

        derived? = reads.(:destinations) and reads.(:type_for_destination)
        literals = b |> collect_strings() |> Enum.sort()

        %{
          id: "labels.visual_types_derived",
          remediation:
            "une clause de `type_for_destination/1` sans sa destination dans `@destinations` " <>
              "produit un type visuel que `visual_types/0` ne seme pas — il naitra gris et sans " <>
              "description, comme `type:workshop` pendant seize jours",
          status: if(n_clauses == n_dest and derived? and literals == [], do: :pass, else: :fail),
          evidence:
            if(n_clauses == n_dest,
              do: [],
              else: [
                "#{rel}: #{n_clauses} clause(s) type_for_destination/1 pour #{n_dest} @destinations"
              ]
            ) ++
              if(derived?,
                do: [],
                else: [
                  "#{rel}: visual_types/0 ne lit pas @destinations via type_for_destination/1"
                ]
              ) ++
              Enum.map(
                literals,
                &"#{rel}: visual_types/0 ecrit un type en dur: #{inspect(&1)}"
              ),
          note: "visual_types derives from type_for_destination over @destinations"
        }
    end
  end

  # The events.yaml key IS the event `type` (the `source` is a separate field,
  # validated by `Fleet.Event.valid_source?/1`); the registry is keyed by type, there
  # is no dispatch table keyed otherwise. Invariant guarded here: every **consumed**
  # type (`handle_info(%Fleet.Event{type: :X})`, moduledoc examples included)
  # must be a registry key — otherwise the consumer is dead (it waits for a type
  # that cannot be broadcast without `UnregisteredError`). The emitters, for their part, are
  # covered by the fail-loud validation of the broadcast at runtime (an unregistered type
  # crashes its emitter), so this check covers only the consumption side.
  @doc false
  @spec check_events_registry_keys_aligned(String.t()) :: Support.result()
  def check_events_registry_keys_aligned(root) do
    registry = registry_event_keys(root)

    consumed =
      Path.wildcard(Path.join(root, "lib/**/*.ex"))
      |> Enum.flat_map(&consumed_event_types/1)
      |> Enum.uniq()

    unregistered = Enum.reject(consumed, &MapSet.member?(registry, &1))

    # BOTH sides are the population here: an empty registry makes every consumed type unregistered
    # (loud, fine), but an empty SOURCE set makes `consumed` empty and the wall green about a code
    # base it never opened.
    cond do
      measured_nothing?(registry) ->
        broken_result("events.registry.keys_aligned", "key in events.yaml")

      measured_nothing?(Path.wildcard(Path.join(root, "lib/**/*.ex"))) ->
        broken_result("events.registry.keys_aligned", "source under lib/")

      true ->
        %{
          id: "events.registry.keys_aligned",
          remediation:
            "add the consumed type(s) to events.yaml (every handle_info %Fleet.Event{type:} must be a registry key)",
          status: if(unregistered == [], do: :pass, else: :fail),
          evidence: Enum.map(unregistered, &"consumed type outside registry: #{&1}"),
          note: "every consumed type (handle_info %Fleet.Event{type:}) must be an events.yaml key"
        }
    end
  end

  defp registry_event_keys(root) do
    yaml = Path.join(root, "priv/event_router/events.yaml")

    case YamlElixir.read_from_file(yaml) do
      {:ok, %{"events" => events}} when is_map(events) -> MapSet.new(Map.keys(events))
      _ -> MapSet.new()
    end
  end

  # `[^}]*?` allows fields BEFORE `type:` (e.g. `%Fleet.Event{source: :X,
  # type: :Y}`) and traverses multi-line structs (the negation of `}` matches
  # newlines) → captures type-first AND source-first consumers.
  # Known limit: generic `%Fleet.Event{}` consumers + `case type do`
  # (no type literal in the struct) are not covered.
  defp consumed_event_types(file) do
    case File.read(file) do
      {:ok, content} ->
        ~r/%Fleet\.Event\{[^}]*?type:\s*:"?([a-z_][a-z0-9_.]*)"?/
        |> Regex.scan(content)
        |> Enum.map(fn [_, type] -> type end)

      _ ->
        []
    end
  end

  # L'arbre du verificateur de contrats : la tache et ses familles. Une regle, pas une liste — la
  # liste devrait etre tenue a jour a chaque decoupage, et c'est exactement ce qui a lache.
  defp checker_source?("lib/mix/tasks/lcars.contracts.check.ex"), do: true
  defp checker_source?(rel), do: String.starts_with?(rel, "lib/mix/tasks/lcars/contracts/")
end

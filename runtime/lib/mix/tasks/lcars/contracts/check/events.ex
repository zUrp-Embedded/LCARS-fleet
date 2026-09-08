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

  # Event consumers must match `%Fleet.Event{}`, never the legacy tuple `{atom, %{"event_type" => ...}}` — a consumer
  # left on the tuple is dead against the canonical struct (it matches nothing anymore) and the drift is silent. This
  # check measures the real CODE of the targets below and flags any residual `"event_type" =>` read. An instance of the
  # B family (residue_check). The `confirm` = the pattern itself post-strip: an `"event_type" =>` mention in a COMMENT
  # (doc of the legacy-tuple removal) does not count as a violation (otherwise the gate would flag its own
  # documentation). SCOPE: a GLOBAL residue sweep over lib/ — the id's "canon" covers every consumer, matching what the
  # name claims.
  @doc false
  @spec check_event_consumers_canon(String.t()) :: Support.result()
  def check_event_consumers_canon(root) do
    # The check's NAME claims the canon for ALL consumers, so the residue scan covers every source
    # under lib/ — a legacy `"event_type"` tuple REINTRODUCED anywhere fails the gate. A sweep of
    # one file would leave the guarantee narrower than its label.
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

  # The Loader must unwrap the ENVELOPE (kind/metadata/spec.steps) into the single internal
  # FLAT form. There is no flat INPUT: an envelope-less YAML fails the schema before `normalize`.
  # "envelope/flat" = external envelope vs internal flat (one contract, two shapes).
  # Without the unwrap, a consumer reads `workflow_map["steps"]=nil` (steps live under spec.steps).
  @doc false
  @spec check_pipeline_envelope_normalized(String.t()) :: Support.result()
  def check_pipeline_envelope_normalized(root) do
    rel = "lib/fleet/workflow/loader.ex"
    loader = Path.join(root, rel)

    # Anti-hollow-green: matching `~r/normalize/i` over the WHOLE source would turn the rail green as soon as a
    # mere COMMENT contains "normalize", even without the code. So we match the real CODE CLAUSE
    # that unwraps `spec.steps` (the envelope normalization) AND its call, STRIPPING the comment from each
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
      id: "pipeline.envelope.normalized",
      remediation:
        "add the `normalize` unwrap clause for spec.steps so a workflow_map consumer does not read steps=nil",
      status: if(ok?, do: :pass, else: :fail),
      evidence:
        cond do
          not unwrap_clause? ->
            [
              "#{rel}: `defp normalize(%{\"spec\" => %{\"steps\" => ...}})` clause (envelope unwrap) missing → a workflow_map consumer reads steps=nil"
            ]

          not called? ->
            ["#{rel}: `normalize(yaml)` never called at load → envelope not unwrapped"]

          true ->
            []
        end,
      note:
        "Loader UNWRAPS spec.steps via the CODE CLAUSE (`defp normalize(%{\"spec\"…})`) AND calls it at load — matches the code, not a comment (hardened anti-hollow-green)"
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
          # HOLLOW-GREEN GUARD (R0-EVT-012): an ABSENT/invalid events.yaml yielding `[]` reads as
          # `:pass` — the "every handler exists" check passing precisely when the registry it reads
          # is GONE. An
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
  # `@pulled_states` dit qu'un work-item enfile mais jamais TIRE ne possede AUCUN verrou. Des
  # modules raisonnent sur cette regle sans jamais l'appeler : ils la CITENT. Le fournisseur ignore
  # donc qu'il porte une garantie pour eux, et la changer casse leur raisonnement en silence.
  #
  # ⚠ RIEN A COMPARER : cette dependance ne laisse aucune trace executable, contrairement aux autres
  # natures de couture qui s'observent entre deux ensembles ecrits. La seule forme qui la rende
  # verifiable est que le fournisseur la DECLARE — d'ou une valeur dont le seul lecteur est ce mur.
  #
  # DEUX SENS, et le second est celui qui coute : un dependant qui apparait SANS etre declare
  # reintroduit exactement l'angle mort qu'on ferme.
  #
  # ## Preuve, mutations jouees a la pose
  # (a) dependant retire de la declaration -> ECHEC, « cite, non declare » ;
  # (b) fichier declare qui ne cite plus rien -> ECHEC, « declare, ne cite plus ».
  #
  # ANGLE MORT DECLARE : la citation est un GREP. Un module qui raisonnerait sur la regle sans la
  # NOMMER resterait invisible — c'est le prix d'une dependance qui ne s'execute pas.
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
      # pas. S'auto-compter ferait rougir le mur sur sa propre pose — mesure a la pose.
      #
      # ⚠ PAS DE CHEMIN EN DUR vers la tache : une liste de chemins en dur grossit a chaque coupe et
      # rougit la fois ou on l'oublie (un decoupage du verificateur ferait rougir ce mur sur sa
      # propre exemption) — la REGLE la remplace : ce qui vit dans l'arbre du verificateur LIT la
      # regle, il n'en depend jamais.
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

  # ⚠ L'ECHELLE DE SEVERITE EST ECRITE DEUX FOIS, EN DEUX FORMES : l'Elixir porte l'ORDRE — ce a
  # quoi un seuil de blocage se compare — et le schema porte l'APPARTENANCE, ce qu'un juge a le
  # droit d'ecrire. Un `@doc` qui se dit « le SEUL endroit » est donc vrai de l'ordre et faux de
  # l'ensemble.
  #
  # Le cout du desaccord est mesure : un juge ayant ecrit une severite que l'enum ne portait pas a
  # vu TOUTE sa charge mourir pour un mot.
  #
  # Ce check compare les ENSEMBLES, jamais l'ordre — un enum JSON n'en porte aucun.
  #
  # ## Preuve (mutation jouee a la pose)
  # (a) Ajouter `"blocker"` a `severities/0` sans toucher le schema -> ECHEC, la severite est
  #     nommee absente des DEUX enums.
  # (b) Remplacer `"important"` par `"zzz"` dans le seul enum `severity_max` -> ECHEC, une absence
  #     et un surnombre nommes. Une lecture du seul enum par-finding reste verte dessus.
  # Angle mort declare : `"none"` est ecrit ici, pas derive — aucun code Elixir ne le produit, il
  # naît du juge et ne vit que dans le schema. Un second sentinelle du meme genre serait invisible.
  # La valeur que le juge rend quand la mesure est faite et vide. Elle n'existe QUE dans le
  # schema — aucun code Elixir ne la produit — donc le mur la nomme ici plutot que de deviner.
  @severity_max_empty "none"

  @doc false
  @spec check_findings_severities_aligned(String.t()) :: Support.result()
  def check_findings_severities_aligned(root) do
    rel_ex = "lib/fleet/findings_wire.ex"
    rel_json = "priv/workflow/schema/findings.json"

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
    # faite dont le resultat est vide, refusee au fil si elle manque. Un mur qui ne lirait que
    # l'enum par-finding laisserait passer au vert une severite ajoutee ici et pas la, ou l'inverse.
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

        measured_verdict("findings.severities_aligned", %{
          remediation:
            "une severite ecrite d'un seul cote est soit refusee au fil (le juge perd sa charge " <>
              "entiere, cf. le cas `none`), soit acceptee et jamais comparee au `block_at`",
          findings:
            Enum.map(code_only, &"absente de l'enum severity: #{inspect(&1)}") ++
              Enum.map(schema_only, &"absente de severities/0: #{inspect(&1)}") ++
              Enum.map(max_missing, &"absente de l'enum severity_max: #{inspect(&1)}") ++
              Enum.map(max_extra, &"en trop dans severity_max: #{inspect(&1)}"),
          note:
            "findings severity vocabulary: severities/0 == enum severity, " <>
              "et == enum severity_max prive de #{inspect(@severity_max_empty)}"
        })
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
  # La table des kinds est CLOSE : un kind sans clause n'ouvre pas d'issue, il LEVE — et il le fait
  # exactement sur le chemin « un ticket sort du pipeline en silence ». Un temoin qui stubbe
  # l'escalade ne peut pas le voir : une couverture de test ne dit rien d'une COUTURE.
  #
  # L'autre sens coute moins cher et ment autant : une clause SANS producteur se lit comme une
  # garantie que quelque chose sait remonter ce cas.
  #
  # DEUX SOURCES DE PRODUCTION, et il faut les deux : les routes declaratives, et les sites de code
  # ou le kind est argument d'un appel d'escalade. Le catalogue garde deja au boot qu'une route
  # immediate PORTE un kind ; il ne verifie pas que ce kind ait une clause.
  #
  # ## Preuve, mutations jouees a la pose
  # (a) clause retiree pour un kind produit -> ECHEC, kind nomme « sans clause » ;
  # (b) clause ajoutee pour un kind que personne ne produit -> ECHEC, kind nomme « morte » ;
  # (c) kind pose dans les OPTS d'un appelant -> ECHEC. C'est la voie CANONIQUE, et une version
  #     lisant les seuls arguments la manquait entierement ;
  # (d) clause morte maintenue vivante par un COMMENTAIRE de la source declarative -> ECHEC : lire
  #     le texte brut laissait une ligne d'historique nier la mort d'une clause.
  #
  # ANGLE MORT DECLARE : un kind construit dynamiquement est invisible. Aucun n'existe, et un mur
  # precis vaut mieux qu'un mur qui devine.
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
          # Les commentaires tombent AVANT la lecture : sur le texte brut, un
          # `# historique: on avait un jour escalate_kind: zzz_dead` suffit a garder vivante une
          # clause que plus personne ne produit. Un mur qui lit un commentaire mesure
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
      #     CANONIQUE, et la forme (1) seule la manque entierement : l'API publique est
      #     `record_or_escalate/4`, qui ne prend PAS le kind en argument — il voyage dans ses
      #     `opts` jusqu'a `escalate/5` (`incident_registry/escalation.ex`). Sans cette lecture, un
      #     `escalate_kind: :disk_full` ecrit chez un appelant passe au vert et leve un
      #     `FunctionClauseError` a l'execution, exactement le crash que cette table close est
      #     censee rendre impossible.
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

  # ⚠ UN TYPE PRODUIT ET JAMAIS SEME NAIT PARESSEUSEMENT, GRIS ET SANS DESCRIPTION. Les deux
  # ensembles — ce qui produit les types, ce qui les seme — doivent rester egaux, et leur divergence
  # est passee inapercue pendant plus de deux semaines.
  #
  # La DERIVATION ferme la recopie ; ce mur ferme ce qu'elle laisse ouvert — qu'une clause ajoutee
  # cote production ait bien sa destination declaree.
  #
  # ## Preuve (mutation jouee a la pose)
  # (a) Ajouter une clause `def type_for_destination("ops"), do: "type:ops"` sans toucher
  #     `@destinations` -> ECHEC, 3 clauses annoncees pour 2 destinations.
  # (b) Rendre `visual_types/0` a sa forme d'avant — `do: ["type:feature", "type:doc"]`, la recopie
  #     exacte qui a diverge seize jours -> ECHEC, la derivation manquante ET les deux litteraux
  #     nommes. Un mur qui compterait seulement clauses contre destinations resterait vert : il ne
  #     lirait jamais la fonction dont il porte le nom.
  # Son angle mort, declare : il compte, il ne resout pas — deux clauses rendant le MEME type
  # passeraient pour deux destinations manquantes si l'une n'etait pas listee. Le cas ne se presente
  # pas, et un compteur exact vaut mieux qu'un resolveur qui devine.
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

    # LE CORPS DE `visual_types/0`, ET C'EST LE POINT. Compter des clauses contre des destinations
    # sans lire la fonction dont le mur porte le nom laisserait au vert
    # `def visual_types, do: ["type:feature", "type:doc"]` — la recopie exacte qui a diverge
    # pendant seize jours. Un mur qui garde une DERIVATION doit constater la derivation, pas ses
    # deux operandes.
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

        measured_verdict("labels.visual_types_derived", %{
          remediation:
            "une clause de `type_for_destination/1` sans sa destination dans `@destinations` " <>
              "produit un type visuel que `visual_types/0` ne seme pas — il naitra gris et sans " <>
              "description, comme `type:workshop` pendant seize jours",
          # ⚠ TROIS TERMES, TROIS CONSTATS SEPARES. Le verdict est un `and` a trois : comptes egaux,
          # derivation constatee, aucun litteral. Les rendre ensemble est ce qui permet a un temoin
          # d'exercer chaque terme — un `and` de N termes demande N entrees.
          findings:
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
              Enum.map(literals, &"#{rel}: visual_types/0 ecrit un type en dur: #{inspect(&1)}"),
          note: "visual_types derives from type_for_destination over @destinations"
        })
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
end

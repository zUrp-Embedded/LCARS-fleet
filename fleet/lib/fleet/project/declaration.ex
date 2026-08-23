defmodule Fleet.Project.Declaration do
  @moduledoc """
  Single owner of the per-project criticality declaration (`<project>/.lcars.json`,
  schema `declaration-v1`) — writes it at onboarding, reads it at the workflow-map burn.

  **The CARD is the HUMAN's declaration** (elicited by the framing interview — what happens
  if this deliverable is wrong? how long will it live? — and RELAYED by the architect; an
  agent never self-assesses criticality). Undeclared is a LEGITIMATE state: the file is still
  written, complete and schema-valid, running on the delegation default card and explicitly
  marked undeclared — absence is recorded, never fabricated into facts, and never a wall
  (a blocked declaration teaches the human to lie to the arch).

  **The declaration names its card** (`pipeline_default`): the criticality mechanic IS the
  card choice (user arbitration). An explicit `workflow_map` override the catalogue can ANSWER
  is always accepted. A name the loader cannot load is a different question and is REFUSED
  (`refute_unloadable_card/2`): a disagreement with a card is a judgement, a name nobody can burn
  is a typo, and the schema cannot tell them apart because `pipeline_default` is a free string.

  **The declaration also names its THROUGHPUT** (`max_fan`, optional): how many workflow_runs this
  project may hold in flight. It lives HERE and not on the workflow card, and the difference is not
  cosmetic — a card serves one workflow_run and a project can carry several, so a per-card ceiling
  could not bound a project whose tickets route through two different cards. Absent = the fleet
  default (`--max-fan` / `LCARS_MAX_FAN`), which is what made serializing ONE project impossible:
  the counter was per project and the knob was per box.

  Read side: `pipeline_default/2` at the dispatcher's burn. Absent file (legacy project) →
  the delegation default card, silently. A file that no longer NAMES a card (unreadable, or the
  key gone) → LOUD warning + default card. It reads ONLY the card name, never the whole schema:
  a legacy file still carrying a retired key resolves its real card instead of the default.
  """

  require Logger

  # LE NOM DIT A QUI EST LE FICHIER, PAS CE QU'IL CONTIENT. Il s'appelait `intensity.json`, en
  # clair, a la racine du depot — y compris sur un projet ADOPTE, ou la fleet ecrit alors dans
  # l'arbre de quelqu'un d'autre. Un fichier de configuration d'outil porte le point que portent
  # tous les autres (`.gitignore`, `.editorconfig`), et son nom nomme son PROPRIETAIRE : un lecteur
  # qui ouvre un depot inconnu doit pouvoir dire « ca, c'est a l'outil » sans lire le contenu.
  #
  # ⚠ L'EXTENSION N'EST PAS POUR LE LECTEUR — `Jason.decode` ne la regarde pas et aucun glob
  # `*.json` ne ramasse ce fichier. Elle est ce qui evite une COLLISION : `.lcars` tout court est
  # deja, 24 fois dans ce depot, le repertoire d'etat per-humain (`~/.lcars`) et celui du pod
  # (`<pod_dir>/.lcars/system-prompt.md`). Un fichier `.lcars` a la racine d'un workspace, a cote
  # d'un repertoire `.lcars/` dans le home du meme pod, ce sont deux natures sous une chaine — la
  # faute exacte qui a coute le chantier `CLAUDE.md` du 2026-08-12.
  # ⚠ LE NOM VIT DANS `Fleet.Layout`, PAS ICI, depuis 2026-08-13. Il a acquis un SECOND lecteur dans
  # un autre domaine : `Workflow.DeliverableGate` refuse une chaine de livraison qui touche ce
  # fichier (un producteur ne modifie pas la declaration qui choisit son jury), et `Workflow` ne
  # depend pas de `Project` — donc un literal la-bas aurait fait deux sources pour un nom. Layout est
  # l'autorite du rangement et les deux domaines en dependent deja.
  @file_name Fleet.Layout.project_declaration_file()

  # The declaration schema lives in the cap_profile canon (data, not a module frontier —
  # priv paths carry no boundary edge).
  @schema_rel Path.join(["cap_profile", "schema", "declaration-v1.json"])

  @doc """
  Composes, validates and writes `<proj_dir>/.lcars.json` from the onboarding opts
  (`:justification`, `:workflow_map`, `:max_fan` — all optional: nothing declared →
  the delegation default card, marked undeclared).

  `{:error, {:invalid_declaration, errors}}` on a schema-invalid composition (malformed
  FORM is returned to the caller — fixing a format is not lying); `{:error, term}` on a
  write failure. An explicit `workflow_map` override the loader can answer is accepted.
  """
  @spec write(Path.t(), keyword()) :: :ok | {:error, term()}
  def write(proj_dir, opts) when is_binary(proj_dir) and is_list(opts) do
    declaration = compose(opts)

    with :ok <- refute_unloadable_card(Keyword.get(opts, :repo), opts),
         :ok <- validate(declaration) do
      atomic_write(
        Path.join(proj_dir, @file_name),
        Jason.encode!(declaration, pretty: true) <> "\n"
      )
    end
  end

  @doc """
  Refuses an explicit `:workflow_map` a project cannot legitimately declare — absent option is `:ok`.

  A LOADABLE card the human names explicitly stands — naming the card IS the criticality choice.
  A name that does not LOAD is a different question: it is a typo, not a judgement — and the schema
  cannot catch it because `pipeline_default` is a free string, unique only inside one catalogue.

  Enforced HERE, at the single writer, so no entry point can bypass it; the creation verbs call it
  again as a preflight so the refusal lands BEFORE the repo exists, next to the human preflight
  that is there for the same reason.
  """
  @spec refute_unloadable_card(String.t() | nil, keyword()) :: :ok | {:error, term()}
  def refute_unloadable_card(repo, opts) when is_list(opts) do
    case Keyword.get(opts, :workflow_map) do
      name when is_binary(name) and name != "" -> declarable_card(name, repo, opts)
      _ -> :ok
    end
  end

  @doc """
  The rule itself, for a card named EXPLICITLY — whatever verb names it.

  ⚠ **LOADABLE IS NOT DECLARABLE.** A ticket-scoped card (`workshop-direct`, reached by an issue's
  genre) loads perfectly and would route EVERY ticket of the project through a jury-less direct
  seal. Leaving it off a listing closes nothing and reads exactly like closing it — only a refusal
  refuses.

  It lived as `Onboard.require_loadable_card/1`, private, and guarded the card REVISION alone: the
  verb that changes a project's card refused a typo while the verbs that DECLARE it accepted one.
  The refusal names the cards the project's catalogue ships, because one that does not say what to
  write instead sends the operator back through the same call.
  """
  @spec declarable_card(String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def declarable_card(name, repo, opts \\ []) when is_binary(name) do
    lopts = loader_opts(repo, opts)

    # ⚠ L'ABSENCE SE DEMANDE, ELLE NE SE DEDUIT PAS D'UNE EXCEPTION.
    #
    # Ce corps etait un `rescue _ ->` qui rebaptisait TOUTE levee de `load!` en « carte inconnue ».
    # Mesure (BL-6-116) : un `{:error, {:unknown_card, "brief-gate"}}` intermittent sur une carte
    # canon qui EXISTE — douze seeds pleins n'ont rien reproduit, parce que la preuve etait detruite
    # a la source. `load!` leve pour au moins six raisons distinctes : nom non-slug (`Slug.cast!`),
    # carte absente de l'image publiee, YAML illisible, schema invalide, graphe invalide, `spec.ci`
    # manquant. UNE SEULE est une absence ; les cinq autres sont un catalogue casse, et se faisaient
    # passer pour la premiere.
    #
    # La question « cette carte existe-t-elle ici » a une fonction qui y repond, et elle traverse le
    # MEME aiguillage que `load!` — image publiee sinon disque (`canon_names/1` = `image_names` |
    # `disk_canon_names` ; `load!` = `image_card` | `load_from_disk!`). Cette appartenance EST donc le
    # predicat d'absence de `load!`, sans avoir a classer ce qu'il a leve — classer aurait voulu dire
    # reconnaitre un message d'exception, ce qui ment le jour ou le message est reformule.
    #
    # Et le nom non-slug reste refuse comme inconnu, exactement comme avant : `Slug.cast!` VALIDE
    # sans transformer (« validates ... without transforming them »), donc un nom invalide ne figure
    # dans aucune liste. Les deux tests qui l'epinglent (`{:unknown_card, "wfmap/ghost"}`) tiennent.
    if name in Fleet.Workflow.Loader.canon_names(lopts) do
      load_declared(name, lopts)
    else
      refuse_absent(name, repo, lopts)
    end
  end

  # La carte EXISTE la ou on la cherche. Ce qui sort d'ici n'est donc jamais une absence : c'est un
  # catalogue casse, et il est nomme comme tel.
  #
  # On ne laisse PAS l'exception voler — cette fonction est aussi le preflight de la creation de
  # projet (`Onboard`), dont tout le contrat est de rendre `:ok | {:error, _}` AVANT que le depot
  # existe. Mais le terme d'erreur porte desormais le message d'origine, et le journal est en
  # `error` et non en `warning` : au prochain flake, la cause est ecrite, pas a redecouvrir.
  defp load_declared(name, lopts) do
    case Fleet.Workflow.Loader.load!(name, lopts) do
      %{"scope" => "project"} ->
        :ok

      %{"scope" => scope} ->
        {:error, {:card_not_project_scoped, name, scope}}
    end
  rescue
    e ->
      Logger.error(
        "ProjectDeclaration: card #{inspect(name)} IS declared by the catalogue but FAILED TO LOAD — " <>
          "#{inspect(e.__struct__)}: #{Exception.message(e)} (looked in #{inspect(lopts)})"
      )

      {:error, {:card_load_failed, name, Exception.message(e)}}
  end

  # Le refus d'une carte reellement absente d'ici. Corps inchange depuis le 2026-08-17 — seule son
  # entree a change : il n'est plus atteint par la retombee d'une exception, mais par un test
  # d'appartenance. Les deux termes qu'il rend sont les memes, et leurs appelants aussi.
  defp refuse_absent(name, repo, lopts) do
    # ⚠ « INCONNUE ICI » N'EST PAS « INCONNUE », ET LA DIFFERENCE EST LA SEULE CHOSE UTILE A DIRE.
    # Mesure du 2026-08-17, transcript d'un starfleet : le guichet lui presente `standard` du
    # catalogue `web-demo` (la liste NOMME le catalogue de chaque carte), il la choisit, et
    # `project_create` la refuse en `{:unknown_card, "standard"}` — parce que l'appel n'a pas
    # porte `catalogue`, donc l'org a pris le defaut et la carte s'est resolue chez `fleet`. Le
    # refus enumerait alors les cartes de `fleet`, ou celle demandee ne figure evidemment pas :
    # un message qui accuse le NOM alors que ce qui manque est l'ARGUMENT VOISIN.
    #
    # L'agent a bien travaille — il a verifie qu'aucun depot n'avait ete cree a moitie, il a
    # refuse de contourner, et il a rendu la main en nommant deux sorties. Il a seulement conclu
    # « la creation ne sait resoudre que les cartes de fleet », ce qui est faux : elle resout dans
    # le catalogue du PROJET, et le projet avait atterri dans le mauvais.
    #
    # On ne devine PAS a sa place — le catalogue fixe l'org du projet POUR SA VIE, donc choisir
    # pour lui serait le pire des services. On NOMME : la carte existe la-bas, voici l'argument.
    elsewhere = carriers_of(name, repo)

    Logger.warning(
      "ProjectDeclaration: card #{inspect(name)} is not declarable by a project — REFUSED " <>
        "(available: #{Enum.join(Fleet.Workflow.Loader.canon_names(lopts), ", ")})" <>
        case elsewhere do
          [] ->
            ""

          cats ->
            " — it EXISTS in #{Enum.join(cats, ", ")}: pass `catalogue`, the project's org is fixed for life"
        end
    )

    case elsewhere do
      [] -> {:error, {:unknown_card, name}}
      cats -> {:error, {:card_in_another_catalogue, name, cats}}
    end
  end

  # Les porteurs, MOINS celui du projet. La question « qui porte cette carte » a UNE reponse et elle
  # vit chez le loader (`catalogues_carrying/1`, lue aussi par l'inference d'org du guichet) : la
  # deriver ici en second ferait de ce refus et de cette inference deux verites d'un meme fait.
  defp carriers_of(name, repo) do
    mine =
      case Fleet.Workflow.Loader.card_root_for_repo(repo) do
        nil ->
          nil

        dir ->
          Enum.find_value(
            Fleet.Workflow.Loader.card_scopes(),
            &if(&1.dir == dir, do: &1.catalogue)
          )
      end

    Fleet.Workflow.Loader.catalogues_carrying(name) -- [mine]
  end

  # LA MEME RESOLUTION QUE LES LECTEURS, et c'est une condition de correction et non un detail :
  # un CONTROLE plus strict que ce qu'il garde refuse des configurations que le lecteur accepte.
  # Deux niveaux, dans cet ordre :
  #   * l'override FIN `:workflow_maps_root` gagne — « the fixture's own door », dit le loader, et
  #     `Roles.load_project_card/2` le respecte deja de la meme facon ;
  #   * sinon le catalogue du PROJET, par son org. La version privee d'ou vient cette regle
  #     chargeait sans options du tout, donc dans l'image du catalogue par DEFAUT : un projet d'une
  #     autre org se voyait refuser une carte que son propre catalogue publie.
  defp loader_opts(repo, opts) do
    case Keyword.take(opts, [:workflow_maps_root]) do
      [] -> Fleet.Workflow.Loader.card_opts_for_repo(repo)
      given -> given
    end
  end

  # CI-07
  defp atomic_write(path, content) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _} = err ->
        _ = File.rm(tmp)
        err
    end
  end

  @doc """
  Returns the project's declared card. Absence quietly uses the delegation default; invalid or
  unreadable data logs, records an incident, and uses that default.
  """
  @spec pipeline_default(String.t(), keyword()) :: String.t()
  def pipeline_default(repo, opts \\ []) when is_binary(repo) do
    root = Keyword.get(opts, :code_root, Fleet.Layout.code_root())
    path = Path.join([root, Fleet.Layout.project_name(repo), @file_name])

    # Legacy-tolerant read: only that a card is NAMED, never the whole schema. A legacy `.lcars.json`
    # still carrying a retired key (`level`, `nature`) is `additionalProperties: false`-invalid but
    # its card is intact — full-validating here would drop every existing project to the default. We
    # read the raw access (not a guard-bound var) on purpose: it keeps the pre-existing `binary()`
    # success type (a verified catalogue that ships cards always names a loadable default), so the
    # spec stays honest and `load_project_card` keeps its non-nil guarantee.
    with {:ok, raw} <- File.read(path),
         {:ok, declaration} <- Jason.decode(raw),
         true <- is_binary(declaration["pipeline_default"]) do
      declaration["pipeline_default"]
    else
      {:error, :enoent} ->
        Fleet.Project.Roles.delegation_workflow_map(opts)

      other ->
        Logger.warning(
          "ProjectDeclaration: #{path} unreadable/invalid (#{inspect(other)}) — " <>
            "falling back to the delegation default card (re-declare to repair)"
        )

        incident =
          Keyword.get(opts, :incident_fun, &Fleet.Project.Incidents.emit/4)

        _ =
          try do
            incident.("declaration", repo, :declaration_invalid,
              reason_detail: "#{path}: #{inspect(other)}"
            )
          catch
            kind, why ->
              Logger.warning(
                "ProjectDeclaration: fallback incident NOT recorded (#{inspect(kind)}: #{inspect(why)})"
              )
          end

        Fleet.Project.Roles.delegation_workflow_map(opts)
    end
  end

  @doc """
  The project's declared throughput — workflow_runs in flight, `nil` if undeclared.

  Deliberately QUIETER than `pipeline_default/2` on a broken file: that one records an INCIDENT,
  because substituting a card changes the project's judgment layer. Falling back to the fleet
  default throughput changes a RATE. Alarming twice for one bad file would teach a reader that the
  second alarm means something new. The resolution + clamp belong to `Admission.max_fan/2`, the
  single owner of the ceiling; this function only reports what the human wrote.
  """
  @spec declared_max_fan(String.t(), keyword()) :: pos_integer() | nil
  def declared_max_fan(repo, opts \\ []) when is_binary(repo) do
    root = Keyword.get(opts, :code_root, Fleet.Layout.code_root())
    path = Path.join([root, Fleet.Layout.project_name(repo), @file_name])

    with {:ok, raw} <- File.read(path),
         {:ok, %{"max_fan" => n}} when is_integer(n) <- Jason.decode(raw) do
      n
    else
      _ -> nil
    end
  end

  defp compose(opts) do
    justification = Keyword.get(opts, :justification)
    card = Keyword.get(opts, :workflow_map)

    # Naming a card IS the declaration (crit_quarantine): there is no separate level. A write with
    # no card is an undeclared project — recorded honestly, running on the delegation default.
    declared? = is_binary(card)

    onboarded_by = Keyword.get(opts, :onboarded_by) || "unknown"

    base = %{
      "_schema" => "lcars/declaration-v1",
      "declared_at" => Date.to_iso8601(Date.utc_today()),
      "declared_by" => if(declared?, do: onboarded_by, else: "system-default"),
      "justification" => justification || default_justification(card),
      "pipeline_default" => card || Fleet.Project.Roles.delegation_workflow_map(opts)
    }

    # Written ONLY when declared. A key absent means "the fleet default", and materializing that
    # default into the file would freeze today's flag into the project's permanent record — the
    # human would then be bound by a number they never chose.
    case Keyword.get(opts, :max_fan) do
      n when is_integer(n) -> Map.put(base, "max_fan", n)
      _ -> base
    end
  end

  defp default_justification(card) do
    if is_binary(card) do
      "Carte choisie explicitement par l'humain : #{card}."
    else
      "NON DÉCLARÉ — défaut système : l'humain n'a pas choisi de carte " <>
        "(on ne sait pas, donc on juge)."
    end
  end

  defp validate(declaration) do
    case ExJsonSchema.Validator.validate(schema(), declaration) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_declaration, errors}}
    end
  end

  defp schema do
    path = Path.join([to_string(:code.priv_dir(:lcars_fleet)), @schema_rel])
    Fleet.SchemaCache.resolve_json_schema!({__MODULE__, :schema, path}, path)
  end
end

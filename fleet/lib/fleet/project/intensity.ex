defmodule Fleet.Project.Intensity do
  @moduledoc """
  Single owner of the per-project criticality declaration (`<project>/.lcars.json`,
  schema `intensity-v1`) — writes it at onboarding, reads it at the workflow-map burn.

  **The level is the HUMAN's declaration** (elicited by the framing interview — what
  happens if this deliverable is wrong? how long will it live? — and RELAYED by the
  architect; an agent never self-assesses criticality). Undeclared is a LEGITIMATE state:
  the file is still written, complete and schema-valid, as an HONEST C0 default explicitly
  marked undeclared — absence is recorded, never fabricated into facts, and never a wall
  (a blocked declaration teaches the human to lie to the arch).

  **The declaration names its card** (`pipeline_default`): the criticality mechanic IS the
  card choice (user arbitration). An explicit `workflow_map` override that the catalogue can
  ANSWER is always accepted — off-matrix (level outside the card's `applicable_intensity`) it is
  logged LOUD and the disagreement stays visible in the committed file; the human has the last
  word. A name the loader cannot load is a different question and is REFUSED
  (`refute_unloadable_card/2`): a disagreement with a card is a judgement, a name nobody can burn
  is a typo, and the schema cannot tell them apart because `pipeline_default` is a free string.

  **The declaration also names its THROUGHPUT** (`max_fan`, optional): how many workflow_runs this
  project may hold in flight. It lives HERE and not on the workflow card, and the difference is not
  cosmetic — a card serves one workflow_run and a project can carry several, so a per-card ceiling
  could not bound a project whose tickets route through two different cards. Absent = the fleet
  default (`--max-fan` / `LCARS_MAX_FAN`), which is what made serializing ONE project impossible:
  the counter was per project and the knob was per box.

  Read side: `pipeline_default/2` at the dispatcher's burn. Absent file (legacy project) →
  the delegation default card, silently. Malformed/schema-invalid file → LOUD warning +
  default card (a broken declaration never stalls the rail; it is repaired by re-declaring).
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

  # THE LEVEL A PROJECT GETS WHEN NOBODY DECLARED ONE, and it was `C0` — the bottom of the scale,
  # which is a CLAIM: C0 is the disposable posture, and nobody said the work was disposable. The
  # rule this module states two paragraphs up is "absence is recorded, never fabricated into
  # facts"; writing "posture PoC" over silence fabricated one.
  #
  # `C1` is what silence actually buys (user ruling 2026-08-12): we do not know, therefore we
  # judge. It is also the only reading under which the catalogue holds together — `default_card:
  # brief-gate` declares `applicable_intensity: [C1, C2, C3, C4]`, so with `C0` the default card
  # stated itself inapplicable to the only situation it is ever reached in, and nothing said so:
  # the off-matrix warning watched explicit overrides only, and the boot check verified the default
  # card EXISTS, not that it APPLIES.
  #
  # It was a bare literal at its single write site, so nothing else could ask the question — and
  # the boot guard that compares the catalogue's default card against it has to.
  @undeclared_level "C1"

  @doc """
  The level an undeclared project takes — the posture the system records for work nobody qualified.

  Public because the boot guard that checks a catalogue's `default_card` against it must read it
  HERE rather than restate it: two copies of a default are two answers the day one moves.
  """
  @spec undeclared_level() :: String.t()
  def undeclared_level, do: @undeclared_level
  # The intensity schema lives in the cap_profile canon (data, not a module frontier —
  # priv paths carry no boundary edge).
  @schema_rel Path.join(["cap_profile", "schema", "intensity-v1.json"])

  @doc """
  Composes, validates and writes `<proj_dir>/.lcars.json` from the onboarding opts
  (`:intensity_level`, `:intensity_justification`, `:intensity_nature`, `:workflow_map` —
  all optional: nothing declared → the honest C0 default, marked undeclared).

  `{:error, {:invalid_declaration, errors}}` on a schema-invalid composition (malformed
  FORM is returned to the caller — fixing a format is not lying); `{:error, term}` on a
  write failure. An off-matrix `workflow_map` override is accepted + logged LOUD.
  """
  @spec write(Path.t(), keyword()) :: :ok | {:error, term()}
  def write(proj_dir, opts) when is_binary(proj_dir) and is_list(opts) do
    declaration = compose(opts)

    with :ok <- refute_unloadable_card(Keyword.get(opts, :repo), opts),
         :ok <- validate(declaration),
         :ok <- warn_off_matrix(declaration, opts) do
      atomic_write(
        Path.join(proj_dir, @file_name),
        Jason.encode!(declaration, pretty: true) <> "\n"
      )
    end
  end

  @doc """
  Refuses an explicit `:workflow_map` a project cannot legitimately declare — absent option is `:ok`.

  An OFF-MATRIX override stands, and that is a different question: it is the human's judgement
  against the card's own claim about itself, and `write/2` traces the disagreement in the committed
  file. A name that does not LOAD is not a judgement, it is a typo — and the schema cannot catch it
  because `pipeline_default` is a free string, unique only inside one catalogue.

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
    case Fleet.Workflow.Loader.load!(name, loader_opts(repo, opts)) do
      %{"scope" => "project"} ->
        :ok

      %{"scope" => scope} ->
        {:error, {:card_not_project_scoped, name, scope}}
    end
  rescue
    _ ->
      Logger.warning(
        "ProjectIntensity: card #{inspect(name)} is not declarable by a project — REFUSED " <>
          "(available: #{Enum.join(Fleet.Workflow.Loader.canon_names(loader_opts(repo, opts)), ", ")})"
      )

      {:error, {:unknown_card, name}}
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

    with {:ok, raw} <- File.read(path),
         {:ok, declaration} <- Jason.decode(raw),
         :ok <- validate(declaration) do
      declaration["pipeline_default"]
    else
      {:error, :enoent} ->
        Fleet.Project.Roles.delegation_workflow_map(opts)

      other ->
        Logger.warning(
          "ProjectIntensity: #{path} unreadable/invalid (#{inspect(other)}) — " <>
            "falling back to the delegation default card (re-declare to repair)"
        )

        incident =
          Keyword.get(opts, :incident_fun, &Fleet.Project.Incidents.record_or_escalate/4)

        _ =
          try do
            incident.("intensity", repo, :declaration_invalid,
              reason_detail: "#{path}: #{inspect(other)}"
            )
          catch
            kind, why ->
              Logger.warning(
                "ProjectIntensity: fallback incident NOT recorded (#{inspect(kind)}: #{inspect(why)})"
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
    level = Keyword.get(opts, :intensity_level)
    justification = Keyword.get(opts, :intensity_justification)
    card = Keyword.get(opts, :workflow_map)

    declared? = is_binary(level) or is_binary(card)

    onboarded_by = Keyword.get(opts, :onboarded_by) || "unknown"

    base = %{
      "_schema" => "lcars/intensity-v1",
      "declared_at" => Date.to_iso8601(Date.utc_today()),
      "declared_by" => if(declared?, do: onboarded_by, else: "system-default"),
      "justification" => justification || default_justification(level, card),
      "pipeline_default" => card || Fleet.Project.Roles.delegation_workflow_map(opts)
    }

    base =
      cond do
        is_binary(level) -> Map.put(base, "level", level)
        is_binary(card) -> base
        true -> Map.put(base, "level", @undeclared_level)
      end

    base =
      case Keyword.get(opts, :intensity_nature) do
        nature when is_binary(nature) and nature != "" -> Map.put(base, "nature", nature)
        _ -> base
      end

    # Written ONLY when declared. A key absent means "the fleet default", and materializing that
    # default into the file would freeze today's flag into the project's permanent record — the
    # human would then be bound by a number they never chose.
    case Keyword.get(opts, :max_fan) do
      n when is_integer(n) -> Map.put(base, "max_fan", n)
      _ -> base
    end
  end

  defp default_justification(level, card) do
    cond do
      is_binary(level) ->
        "Justification non fournie — niveau #{level} déclaré par l'humain."

      is_binary(card) ->
        "Niveau non déclaré — carte choisie explicitement par l'humain : #{card}."

      true ->
        "NON DÉCLARÉ — défaut système (niveau #{@undeclared_level} : on ne sait pas, donc on " <>
          "juge). L'humain n'a pas déclaré la criticité."
    end
  end

  defp validate(declaration) do
    case ExJsonSchema.Validator.validate(schema(), declaration) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_declaration, errors}}
    end
  end

  # IT WATCHED ONLY THE EXPLICIT OVERRIDE, and the `@moduledoc` promises otherwise: "off-matrix is
  # logged LOUD and the disagreement stays visible in the committed file". A card arriving from the
  # catalogue's `default_card` never passed here — so the one provenance NOBODY chose was also the
  # one nobody was told about. Measured: every undeclared project ran on a card whose own matrix
  # excluded it, in silence, for as long as the two defaults disagreed.
  #
  # The wording still separates the two provenances, because the reader's next gesture differs: an
  # override is the human's last word and stands; a DEFAULT landing off-matrix is a catalogue that
  # does not hold together, and it gets repaired there.
  defp warn_off_matrix(declaration, opts) do
    card = declaration["pipeline_default"]
    override = Keyword.get(opts, :workflow_map)

    with level when is_binary(level) <- declaration["level"],
         name when is_binary(name) <- card,
         %{"applicable_intensity" => levels} when levels != [] <- safe_load_card(name, opts),
         false <- level in levels do
      provenance = if override == name, do: "explicit override", else: "catalogue default"

      Logger.warning(
        "ProjectIntensity: card #{inspect(name)} (#{provenance}) is OFF-MATRIX for level " <>
          "#{level} (card claims #{inspect(levels)}) — traced in the committed declaration"
      )

      :ok
    else
      _ -> :ok
    end
  end

  # Scoped to the PROJECT's catalogue: a card name is unique only inside one, and read with no root
  # this resolved in the default catalogue's image — the same defect the rest of the read side
  # carried. `:repo` absent (a caller with no project in hand) keeps the default root.
  # ⚠ CE MESSAGE PROMETTAIT UN REPLI QUI N'EXISTE QUE D'UN COTE. Il disait « the burn will fall
  # back to the default card » : vrai pour `Roles.load_project_card/2`, qui rattrape et enregistre
  # un incident, et FAUX pour `StepDispatcher`, qui charge en direct et refuse d'onboarder. Une
  # issue sans route echouait donc a chaque tick, indefiniment, sous un log qui annoncait un repli.
  #
  # Depuis `refute_unloadable_card/2`, un override explicite n'arrive plus jusqu'ici : ce qui reste
  # est une carte par DEFAUT du catalogue qui ne charge pas — un catalogue qui ne tient pas
  # ensemble, et ca se repare la, pas dans une declaration de projet.
  defp safe_load_card(name, opts) do
    repo = Keyword.get(opts, :repo)
    Fleet.Workflow.Loader.load!(name, Fleet.Workflow.Loader.card_opts_for_repo(repo))
  rescue
    e ->
      Logger.warning(
        "ProjectIntensity: catalogue default card #{inspect(name)} does not load " <>
          "(#{Exception.message(e)}) — the off-matrix check is SKIPPED and the declaration is " <>
          "written as-is; repair the catalogue, this project cannot be dispatched under that name"
      )

      %{}
  end

  defp schema do
    path = Path.join([to_string(:code.priv_dir(:lcars_fleet)), @schema_rel])
    Fleet.SchemaCache.resolve_json_schema!({__MODULE__, :schema, path}, path)
  end
end

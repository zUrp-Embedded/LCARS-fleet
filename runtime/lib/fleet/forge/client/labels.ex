defmodule Fleet.Forge.Client.Labels do
  @moduledoc """
  Les labels du protocole : leur pose, leur creation a la demande, leur couleur, leur description.

  Un label de ce depot n'est pas une etiquette libre — c'est un ETAT de la machine a etats que la
  forge PORTE. Sa couleur et sa description sont donc des donnees du protocole, pas de la
  decoration : la description est ce qu'un humain lit dans l'interface de la forge quand il se
  demande ce que le runtime a voulu dire, et c'est le seul endroit ou il peut le lire.

  ⚠ AUCUNE DE CES FONCTIONS N'EST DANS LA COUTURE : l'API atteinte par `forge().x` reste
  entierement sur `Fleet.Forge.Client`, ce module ne porte que de la machinerie. Publiques parce
  qu'elles traversent une frontiere de module — un fait de decoupage, pas une surface d'API, et
  `@doc false` le dit.

  `card_description/2` lit la carte par `Fleet.Workflow.Loader.load!/2`, dans le catalogue que
  le depot nomme (`card_opts_for_repo/1`) : le meme `wfmap/<nom>` existe dans deux catalogues avec
  deux descriptions.
  """

  alias Fleet.Forge.Client.Transport

  require Logger

  # Les memes primitives que le client : ce module appelle la forge, il n'en reimplemente aucune.
  # `only:` restreint a ce qui sert ici — un import large rendrait invisible le jour ou l'une
  # d'elles cesse d'etre utilisee.
  import Fleet.Forge.Client.Transport,
    only: [http_get: 2, http_post: 3, http_patch: 3, paginate: 3]

  import Fleet.Forge.Client.UrlSafe, only: [encode_repo: 1]

  # Les libelles du protocole, LIES ICI parce qu'ils servent en position de MOTIF
  # (`def label_color(@lbl_in_flight)`) : un appel de fonction y est interdit. La source reste
  # `Fleet.Labels` — ces lignes en sont une derivation, jamais une seconde verite.
  @lbl_in_flight Fleet.Labels.in_flight()
  @lbl_awaits_arch Fleet.Labels.awaits_arch()
  @lbl_destination_workshop Fleet.Labels.destination_workshop()
  @lbl_stage_review Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_review()
  @lbl_stage_merged Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_merged()
  @lbl_stage_retired Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_retired()

  @doc false
  # Les labels portes par une issue.
  @spec get_issue_labels(Transport.config(), String.t(), integer()) ::
          {:ok, [map()]} | {:error, term()}
  def get_issue_labels(config, repo, issue_number) do
    case http_get(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/labels") do
      {:ok, labels} when is_list(labels) -> {:ok, labels}
      {:error, _} = err -> err
    end
  end

  @doc false
  # Pose un label, en le CREANT sur le depot s'il n'y existe pas encore.
  @spec add_issue_label(Transport.config(), String.t(), integer(), String.t()) ::
          :ok | {:error, term()}
  def add_issue_label(config, repo, issue_number, label_name) do
    case post_issue_label(config, repo, issue_number, label_name) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        with :ok <- ensure_repo_label(config, repo, label_name),
             {:ok, true} <- post_issue_label(config, repo, issue_number, label_name) do
          :ok
        else
          _ -> {:error, {:label_not_added, label_name}}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc false
  # Le POST nu — `{:ok, false}` quand la forge ne connait pas le label.
  @spec post_issue_label(Transport.config(), String.t(), integer(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def post_issue_label(config, repo, issue_number, label_name) do
    case http_post(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/labels", %{
           labels: [label_name]
         }) do
      {:ok, body} when is_list(body) -> {:ok, Enum.any?(body, &(&1["name"] == label_name))}
      {:ok, _non_list} -> {:ok, false}
      {:error, _} = err -> err
    end
  end

  @doc false
  # Verifie apres coup que les labels attendus existent bien sur le depot.
  @spec verify_labels_present(Transport.config(), String.t(), [String.t()]) ::
          :ok | {:error, term()}
  def verify_labels_present(config, repo, expected) do
    case paginate(config, "/repos/#{encode_repo(repo)}/labels", "") do
      {:ok, labels} when is_list(labels) ->
        present = MapSet.new(labels, & &1["name"])

        case Enum.reject(expected, &MapSet.member?(present, &1)) do
          [] -> :ok
          missing -> {:error, {:labels_missing, missing}}
        end

      other ->
        {:error, {:labels_unverifiable, other}}
    end
  end

  # Creates the missing protocol label at the REPO level. The routing labels (`stage/*`/`wfmap/*`) and the
  # flat locks (`lcars-*`) live PER-REPO: the routing state belongs to ITS repo's issues (the
  # forge = state-store, self-contained per project), and the system account creates them via its **repo-write** —
  # never needing to be org-owner (which `POST /orgs/*/labels` would require → 403 "Must be an organization
  # owner"). Color + description PER FAMILY (the NAME carries the protocol, the description EXPLAINS it to
  # the human hovering over the label on the forge — a cryptic protocol string means
  # nothing outside the code). TRUE idempotence = check-then-create: Gitea does NOT reject a
  # duplicate label NAME (no 409 — verified live 2026-07-18: a double template sync left every
  # label twice, faithfully copied into every generated repo). A failed existence read falls
  # through to the POST (the label matters more than the dedup); a failed POST stays tolerated
  # (`:ok` — it's the re-POST + its verification that decide, cf. `add_issue_label`).
  @doc false
  # Cree le label du depot s'il manque, reconcilie sa couleur s'il existe.
  # Best-effort ASSUME : un echec de listing fait CREER le label, un echec de creation est
  # rattrape a la demande par `add_issue_label/4`. Le semis ne peut donc pas echouer au sens de
  # l'appelant, et le spec dit `:ok` seul — un `{:error, _}` annonce ici serait un retour que la
  # chaine ne produit jamais (dialyzer le voit).
  @spec ensure_repo_label(Transport.config(), String.t(), String.t()) :: :ok
  def ensure_repo_label(config, repo, label_name) do
    case paginate(config, "/repos/#{encode_repo(repo)}/labels", "") do
      {:ok, labels} when is_list(labels) ->
        case Enum.find(labels, &(&1["name"] == label_name)) do
          nil -> create_repo_label(config, repo, label_name)
          existing -> reconcile_label_color(config, repo, existing, label_name)
        end

      _ ->
        create_repo_label(config, repo, label_name)
    end
  end

  # An already-present label keeps its id, and with it every issue wearing it — only its COLOR is
  # reconciled. Creating-only would leave every repo seeded before the palette wearing the old
  # near-white default, and the marker that motivated the palette (`genre/doc`) is precisely one
  # that already exists on all of them: a fix that only reaches repos nobody has created yet is not
  # a fix. Best-effort by design — a repo whose labels cannot be repainted still routes correctly,
  # so this never turns a working forge into a failed seeding.
  @doc false
  # Aligne la couleur d'un label existant sur celle que le protocole declare.
  @spec reconcile_label_color(Transport.config(), String.t(), map(), String.t()) :: :ok
  def reconcile_label_color(config, repo, %{"id" => id, "color" => current}, label_name) do
    wanted = label_color(label_name)

    if normalize_color(current) == normalize_color(wanted) do
      :ok
    else
      _ = http_patch(config, "/repos/#{encode_repo(repo)}/labels/#{id}", %{color: wanted})
      :ok
    end
  end

  def reconcile_label_color(_config, _repo, _existing, _label_name), do: :ok

  # Gitea answers `"ededed"` and accepts `"#ededed"` — comparing the two raw would repaint every
  # label on every pass, forever.
  @doc false
  # Une couleur comparable : sans `#`, en minuscules.
  @spec normalize_color(term()) :: String.t()
  def normalize_color(color) when is_binary(color),
    do: color |> String.trim_leading("#") |> String.downcase()

  def normalize_color(_), do: ""

  @doc false
  # Cree le label sur le depot, avec sa couleur et sa description de protocole.
  @spec create_repo_label(Transport.config(), String.t(), String.t()) :: :ok
  def create_repo_label(config, repo, label_name) do
    # A SCOPED label (name `scope/value`, contains "/") is created MUTUALLY EXCLUSIVE (`exclusive:true`):
    # Gitea removes the old `scope/*` from the issue when a new one is set (verified forge 1.26.1, org AND
    # repo level, by NAME). This is the mechanism of `stage/*` (workflow_map position = visible state
    # machine): native unrepresentability (never 2 steps). The FLAT locks (`lcars-*`) are non-exclusive.
    body = %{
      name: label_name,
      exclusive: String.contains?(label_name, "/"),
      color: label_color(label_name),
      description: label_description(label_name, repo)
    }

    case http_post(config, "/repos/#{encode_repo(repo)}/labels", body) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  # Le NOM porte le protocole, la couleur porte le COUP D'OEIL.
  #
  # ⚠ UN LABEL QUE PERSONNE NE VOIT EST UN LABEL QUI N'EST PAS LA, et il echoue dans la seule
  # direction qui compte : un operateur qui parcourt une liste conclut que le marqueur n'a jamais
  # ete pose. Un defaut quasi-blanc sur une interface blanche produit exactement ca — present dans
  # l'API, absent a l'humain.
  #
  # Une teinte par famille de PROTOCOLE, et les etapes gardent une progression lisible sans legende.
  # La palette est reservee a ce qui SIGNIFIE quelque chose mecaniquement : le registre decoratif
  # recoit un neutre visible plutot que d'emprunter une teinte de protocole, pour qu'une rime de
  # couleur ne suggere jamais une parente que le code n'a pas.
  @doc false
  # La couleur de protocole d'un label — donnee, pas decoration.
  @spec label_color(String.t()) :: String.t()
  def label_color(@lbl_in_flight), do: "#FF9900"
  def label_color(@lbl_awaits_arch), do: "#CC6666"
  def label_color(@lbl_destination_workshop), do: "#33BBCC"
  def label_color("stage/brief-review"), do: "#6699CC"
  def label_color("stage/build"), do: "#FFCC33"
  def label_color(@lbl_stage_review), do: "#9966CC"
  def label_color(@lbl_stage_merged), do: "#99CC66"
  # Deliberately NOT a green: `retired` is the twin of `merged` in position and its opposite in
  # meaning — a ticket that closed without delivering. A shared hue would read as a delivery.
  def label_color(@lbl_stage_retired), do: "#777788"
  def label_color("wfmap/" <> _map), do: "#CC99CC"
  def label_color("type:" <> _kind), do: "#999999"
  def label_color(_), do: "#999999"

  # Description PER FAMILY (Gitea tooltip on hover) — the NAME stays the protocol (LCARS vocab intact,
  # parsed as-is by the code), the description is the ONLY place where we explain in plain terms to a human
  # looking at the forge without the code in front of them. `wfmap/<map>` and `stage/<step>` have
  # dynamic values (map name / step name varying by workflow_map) → match on the PREFIX, not the
  # exact value (unlike `label_color`, which differentiates each stage it knows by name).

  @doc false
  # Ce qu'un humain lit sur la forge pour savoir ce que le runtime a voulu dire.
  @spec label_description(String.t()) :: String.t()
  def label_description(@lbl_in_flight),
    do:
      "Verrou : un pod travaille déjà cette brique (anti double-spawn). Levé par le système en fin de step — jamais à retirer à la main."

  def label_description(@lbl_awaits_arch),
    do:
      "Cette issue attend une action HUMAINE via l'architecte (verdict escalade/halt/redirect) — le poller la laisse tranquille tant qu'il est posé."

  def label_description("stage/" <> _step),
    do:
      "Étape COURANTE de cette issue dans son plan (workflow_map) — bouge à chaque avancée (mutex : une seule à la fois)."

  def label_description("wfmap/" <> map), do: label_description("wfmap/" <> map, nil)

  # Ce texte est lu par un HUMAIN sur la forge, et il nomme la face `workshop` : c'est la que part
  # le livrable documentaire. `ops` est le registre que le runtime ecrit, qu'aucun producteur ne
  # touche — une description qui nommerait `ops` enverrait le lecteur vers l'arbre exactement inverse.
  def label_description(@lbl_destination_workshop),
    do:
      "Ticket DOCUMENTAIRE : le système l'aiguille vers la voie doc (branche workshop, rédigée par le scribe) au lieu de la voie code. Posé à la création, lu une fois — c'est lui qui route, pas le `type:`."

  def label_description("type:" <> _kind),
    do:
      "Type VISUEL du ticket — décoratif, aucun mécanisme ne le lit. Il suit la destination : ce qui ROUTE est `destination/*`."

  def label_description(_),
    do: "Label protocole LCARS (auto-créé, wire-protocol forge-state-machine)."

  # The card's description comes from the CATALOGUE THAT SERVES THE REPO: the same `wfmap/<name>`
  # exists in two catalogues with two descriptions, and the repo's org names which one.
  @doc false
  @spec label_description(String.t(), String.t() | nil) :: String.t()
  def label_description("wfmap/" <> map, repo) do
    case card_description(map, repo) do
      {:ok, desc} ->
        String.slice(
          "Le PLAN (workflow_map) de cette issue — posé à l'onboarding, fixe. Carte : " <> desc,
          0,
          240
        )

      :error ->
        "Le PLAN (workflow_map) que suit cette issue — posé UNE FOIS à l'onboarding, ne change jamais (fixe, pas un verrou)."
    end
  end

  def label_description(name, _repo), do: label_description(name)

  @doc false
  # La description d'un label de carte de role, lue dans le catalogue du depot.
  @spec card_description(String.t(), String.t() | nil) :: {:ok, String.t()} | :error
  def card_description(map, repo) do
    case Fleet.Workflow.Loader.load!(map, Fleet.Workflow.Loader.card_opts_for_repo(repo))[
           "description"
         ] do
      desc when is_binary(desc) and desc != "" -> {:ok, desc}
      _ -> :error
    end
  rescue
    _ -> :error
  end
end

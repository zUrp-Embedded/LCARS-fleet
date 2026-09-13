defmodule Fleet.Forge.Client.Labels do
  @moduledoc """
  Pose et palette des labels, internes a la boundary de `Fleet.Forge.Client`.
  La description de `wfmap/<nom>` vient du catalogue choisi pour le depot par
  `Fleet.Workflow.Loader.card_opts_for_repo/1` : un meme nom peut designer deux cartes.
  """

  alias Fleet.Forge.Client.Transport

  import Fleet.Forge.Client.Transport,
    only: [http_get: 2, http_post: 3, http_patch: 3, paginate: 3]

  import Fleet.Forge.Client.UrlSafe, only: [encode_repo: 1]

  # Derives de Fleet.Labels pour pouvoir les utiliser dans les motifs de fonction.
  @lbl_in_flight Fleet.Labels.in_flight()
  @lbl_awaits_arch Fleet.Labels.awaits_arch()
  @lbl_destination_workshop Fleet.Labels.destination_workshop()
  @lbl_stage_review Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_review()
  @lbl_stage_merged Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_merged()
  @lbl_stage_retired Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_retired()

  @doc false
  # Une seule reponse, sans pagination ni validation des entrees.
  @spec get_issue_labels(Transport.config(), String.t(), integer()) ::
          {:ok, [map()]} | {:error, term()}
  def get_issue_labels(config, repo, issue_number) do
    case http_get(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/labels") do
      {:ok, labels} when is_list(labels) -> {:ok, labels}
      {:error, _} = err -> err
    end
  end

  @doc false
  # Si le POST reussit sans renvoyer le nom, tente la creation puis un seul nouveau POST.
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
  # Verifie le nom dans la reponse au POST, sans relecture. Non-liste ou nom absent => false.
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
  # Verifie les noms seulement, pas leur unicite, couleur, description ou exclusivite.
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

  @doc false
  # Portee depot : repo-write suffit sans demander les droits org-owner de /orgs/*/labels.
  # Le bench Gitea du 2026-07-18 acceptait les noms en double : lire avant de creer limite
  # les doublons sans atomicite. Une lecture echouee tente quand meme la creation.
  # Les erreurs HTTP de creation/reconciliation sont ignorees ; :ok ne prouve pas le semis.
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

  @doc false
  # Garde l'id et les associations aux issues ; ne reconcilie que la couleur.
  # Champs id/color absents => aucune action ; resultat du PATCH ignore, sans relecture.
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

  @doc false
  # Evite un PATCH repete pour "ededed" contre "#ededed" ; les non-binaires deviennent "".
  @spec normalize_color(term()) :: String.t()
  def normalize_color(color) when is_binary(color),
    do: color |> String.trim_leading("#") |> String.downcase()

  def normalize_color(_), do: ""

  @doc false
  # Cree le label sur le depot, avec sa couleur et sa description de protocole.
  @spec create_repo_label(Transport.config(), String.t(), String.t()) :: :ok
  def create_repo_label(config, repo, label_name) do
    # Demande l'exclusivite pour tout nom contenant "/" (dont stage/*), pas les locks plats.
    # Le remplacement par scope etait observe sur Gitea 1.26.1, org/depot, par nom.
    # Les labels existants ne sont pas migres ni cette propriete relue ici.
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

  @doc false
  # Palette par famille ; defaut gris visible sans suggerer une parente de protocole.
  @spec label_color(String.t()) :: String.t()
  def label_color(@lbl_in_flight), do: "#FF9900"
  def label_color(@lbl_awaits_arch), do: "#CC6666"
  def label_color(@lbl_destination_workshop), do: "#33BBCC"
  def label_color("stage/brief-review"), do: "#6699CC"
  def label_color("stage/build"), do: "#FFCC33"
  def label_color(@lbl_stage_review), do: "#9966CC"
  def label_color(@lbl_stage_merged), do: "#99CC66"
  # Retired ferme sans livraison : eviter le vert de merged.
  def label_color(@lbl_stage_retired), do: "#777788"
  def label_color("wfmap/" <> _map), do: "#CC99CC"
  def label_color("type:" <> _kind), do: "#999999"
  def label_color(_), do: "#999999"

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

  # Workshop porte le livrable documentaire ; ops est le registre ecrit par le runtime.
  def label_description(@lbl_destination_workshop),
    do:
      "Ticket DOCUMENTAIRE : le système l'aiguille vers la voie doc (branche workshop, rédigée par le scribe) au lieu de la voie code. Posé à la création, lu une fois — c'est lui qui route, pas le `type:`."

  def label_description("type:" <> _kind),
    do:
      "Type VISUEL du ticket — décoratif, aucun mécanisme ne le lit. Il suit la destination : ce qui ROUTE est `destination/*`."

  def label_description(_),
    do: "Label protocole LCARS (auto-créé, wire-protocol forge-state-machine)."

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
  # Description non vide du catalogue du depot ; champ invalide ou exception => :error.
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

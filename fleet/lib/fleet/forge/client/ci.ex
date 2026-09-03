defmodule Fleet.Forge.Client.CI do
  @moduledoc """
  L'etat CI d'un commit, reduit depuis les contextes que la forge empile.

  Gitea ne rend pas UN etat : elle rend la LISTE de tous les statuts jamais postes sur un SHA, un
  par contexte et par tentative. Repondre « la CI est verte » demande donc de prendre le statut
  COURANT de chaque contexte, puis le pire d'entre eux.

  ⚠ L'ORDRE DE LA LISTE N'EST PAS CELUI QU'ON CROIT, ET CE CODE NE S'Y FIE PAS. Mesure du
  2026-09-02 contre une forge reelle (`gitea/gitea:1.26.1-rootless`, digest epingle par
  `forge-compose.yml`) : deux statuts postes sur le MEME contexte reviennent du plus ANCIEN au plus
  recent — `id=1` puis `id=2`. Une premiere redaction de ce texte affirmait l'inverse, sur la foi
  d'un commentaire, sans jamais avoir interroge l'API.

  C'est sans consequence ICI parce que le courant se prend par `Enum.max_by(& &1["id"])`, qui ne
  depend d'aucun ordre — mais un lecteur qui aurait cru la phrase et pris `List.first/1` aurait
  rendu le verdict du PREMIER job, pas du dernier. La capture qui l'etablit est versee au depot :
  `test/fixtures/forge/`.

  ⚠ CES FONCTIONS ETAIENT PRIVEES DANS `Fleet.Forge.Client`, ET AUCUNE N'EST DANS LA COUTURE.
  L'API atteinte par `forge().x` reste entierement sur le client — celui-ci ne recoit que de la
  machinerie. Publiques parce qu'elles traversent une frontiere de module, `@doc false` le dit.
  """

  @typedoc """
  Un contexte CI en echec, tel que l'incident le nomme.

  `description` et `target_url` sont `nil` quand la forge ne les a pas remplis — un lien vide vaut
  moins que pas de lien, et `presence/1` les ramene a `nil` plutot que de propager une chaine
  blanche jusqu'a l'affichage.
  """
  @type red :: %{
          context: String.t(),
          description: String.t() | nil,
          target_url: String.t() | nil
        }

  @doc false
  # Les contextes CI en echec, avec leur URL — un par contexte, le plus recent.
  @spec red_contexts([map()]) :: [red()]
  def red_contexts(statuses) do
    statuses
    |> Enum.group_by(& &1["context"])
    |> Enum.flat_map(fn
      {context, group} when is_binary(context) ->
        if Enum.all?(group, &is_integer(&1["id"])) do
          latest = Enum.max_by(group, & &1["id"])

          if latest["status"] in ~w(failure error),
            do: [red_context(context, latest)],
            else: []
        else
          []
        end

      _ ->
        []
    end)
    |> Enum.sort_by(& &1.context)
  end

  @doc false
  # Le couple {contexte, url} d'une entree en echec, ou `nil`.
  @spec red_context(String.t(), map()) :: red()
  def red_context(context, entry) do
    %{
      context: context,
      description: presence(entry["description"]),
      target_url: presence(entry["target_url"])
    }
  end

  @doc false
  # Une chaine non vide, ou `nil` — une chaine blanche n'est pas une valeur.
  @spec presence(term()) :: String.t() | nil
  def presence(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  def presence(_), do: nil

  # LE RANG SE LIT DANS LA DONNEE, PAS DANS L'ORDRE DE LA REPONSE.
  #
  # ⚠ LA DATE ET LA VERSION RESTENT ICI, ET C'EST DELIBERE : la mesure porte sur un SYSTEME EXTERNE
  # dont le comportement peut changer sans nous. Sans sa version, la phrase n'est plus verifiable et
  # un lecteur ne peut pas savoir si elle vaut encore.
  #
  # Mesure du 2026-08-08 sur Gitea 1.26.1 : l'ordre par defaut de `/commits/{ref}/statuses` est
  # OLDEST-first, et des cinq valeurs contractuelles de `sort` seule `leastindex` rend le plus
  # recent en premier — son nom dit le contraire de ce qu'elle fait. Une reduction qui gardait la
  # PREMIERE occurrence par contexte gardait donc la plus ANCIENNE : sur un contexte pose
  # `success` puis `failure`, `commit_ci_state` rendait `{:ok, :success}` — la porte de merge
  # lisant vert sur un commit rouge.
  #
  # `status`, jamais `state` : le contrat porte `state` sur CombinedStatus (l'agregat), `status`
  # sur CommitStatus (l'element), et cet appel liste des CommitStatus.

  @doc false
  # Le DERNIER statut de CHAQUE contexte : la forge empile les tentatives.
  @spec current_per_context([map()]) :: [map()]
  def current_per_context(statuses) do
    statuses
    |> Enum.group_by(& &1["context"])
    |> Enum.flat_map(fn {_context, group} ->
      if Enum.all?(group, &is_integer(&1["id"])) do
        [group |> Enum.max_by(& &1["id"]) |> Map.get("status")]
      else
        # Ordre indeterminable : on garde TOUT le groupe, donc `worst_ci_state/1` prend le pire.
        # Ne jamais rendre le meilleur d'un ensemble qu'on ne sait pas ordonner — c'est une porte
        # de merge qui lit le resultat.
        Enum.map(group, & &1["status"])
      end
    end)
  end

  # Worst-of, in the order that matters to a merge decision: one failure sinks it; otherwise any
  # unfinished run means "not yet", never "yes".
  @doc false
  # Le pire etat de la liste — un seul rouge suffit a rendre la CI rouge.
  @spec worst_ci_state([map()] | []) :: atom()
  def worst_ci_state([]), do: :none

  # LES SIX ETATS QUE LE CONTRAT DECLARE, ET CE QU'ILS VALENT POUR UNE PORTE DE MERGE.
  #
  # `CommitStatus.status` : `pending | success | error | failure | warning | skipped` (enum du
  # swagger de l'instance). La clause fourre-tout « etat inconnu -> :pending » est juste pour un
  # etat VRAIMENT inconnu et fausse pour deux qui sont AU CONTRAT :
  #
  #   * `skipped` — l'etape ne s'est PAS executee et ne devait pas : sa condition `if:` etait
  #     fausse. Elle n'a pas de verdict. La compter comme « pas encore » fait attendre la porte
  #     45 min puis ESCALADER vers un humain — une fausse alarme sur un saut delibere, et une
  #     fausse alarme est ce qui apprend a un humain a ignorer le canal. Un contexte sans verdict ne
  #     VOTE PAS ; si tous sont sautes, il ne reste rien et `:none` (aucun statut) est la reponse
  #     juste, que la porte traite deja en attente bornee.
  #   * `warning` — la verification a TOURNE et n'a pas echoue. La faire bloquer indefiniment est un
  #     etat dont aucun humain ne peut sortir autrement qu'en relancant ; elle ouvre donc la porte,
  #     comme un succes, parce que c'est ce qu'elle est : un succes qui commente.
  #
  # Le fourre-tout couvre l'inconnu REEL, et il rend `:pending` : un etat que ce code ne connait pas
  # ne doit pas elargir la porte.
  def worst_ci_state(states) do
    voting = Enum.reject(states, &(&1 == "skipped"))

    cond do
      voting == [] -> :none
      Enum.any?(voting, &(&1 in ["failure", "error"])) -> :failure
      Enum.any?(voting, &(&1 == "pending")) -> :pending
      Enum.all?(voting, &(&1 in ["success", "warning"])) -> :success
      true -> :pending
    end
  end
end

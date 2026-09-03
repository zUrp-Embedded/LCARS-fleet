defmodule Fleet.Forge.Client.Merge do
  @moduledoc """
  La mecanique de fusion : la tentative, le diagnostic de son refus, la reprise, et le nettoyage de
  la branche de tete.

  Une forge refuse une fusion pour deux raisons qui se ressemblent et ne se traitent pas pareil :
  la PR est REELLEMENT en conflit, ou la forge n'a PAS FINI de calculer si elle l'est
  (`mergeable: null`). Le second cas est transitoire et se retente ; le premier ne se retente
  jamais. Confondre les deux, c'est soit abandonner une fusion possible, soit marteler une fusion
  impossible.

  ⚠ CES FONCTIONS ETAIENT PRIVEES DANS `Fleet.Forge.Client`, ET AUCUNE N'EST DANS LA COUTURE.
  L'API atteinte par `forge().x` reste entierement sur le client — celui-ci ne recoit que de la
  machinerie. Publiques parce qu'elles traversent une frontiere de module, `@doc false` le dit.
  """

  alias Fleet.Forge.Client.Transport

  require Logger

  import Fleet.Forge.Client.Transport, only: [http_get: 2, http_post: 3, http_delete: 2]

  import Fleet.Forge.Client.UrlSafe, only: [encode_repo: 1, encode_seg: 1]

  @doc false
  # La tentative de fusion, avec sa reprise bornee sur `mergeable: null`.
  @spec do_merge(
          Transport.config(),
          String.t(),
          integer(),
          String.t(),
          non_neg_integer(),
          pos_integer()
        ) ::
          :ok | {:error, term()}
  def do_merge(config, repo, index, method, delay, attempts_left) do
    # `do`, la cle du contrat (`MergePullRequestOption`). `"Do"` ne passe que par tolerance du
    # decodeur Go, jamais par contrat — et une tolerance n'est pas une garantie de portage.
    case http_post(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/merge", %{
           "do" => method
         }) do
      {:ok, _} ->
        delete_head_branch_spaced(config, repo, index)
        :ok

      {:error, {:http, 405, body}} = err ->
        # ⚠ LE LIBELLE NE SEPARE PAS LES DEUX FAITS, ET LA MESURE L'A PROUVE.
        #
        # `fleet/probe-rails#24`, 2026-08-18 : conflit git REEL et DEFINITIF
        # (`git merge-tree` -> `CONFLICT (content): journal.txt`), et Gitea rend
        # `405 {"message":"Please try again later"}` — le message reserve au calcul en cours.
        # S'en remettre au libelle seul fait donc retenter un resultat connu d'avance : mesure sur
        # ce cas, 1447 tentatives en 21 h, ~2880 requetes/jour, et 1,6 s de `sleep` a chaque tick
        # du pilote.
        #
        # L'ETAT, LUI, EST FIABLE. On relit la PR : `mergeable: false` tranche le definitif sans
        # dependre d'une chaine. C'est un GET sur un chemin deja en echec — le cas nominal (200) ne
        # le paie jamais.
        case still_unmergeable?(config, repo, index) do
          true ->
            Logger.warning(
              "ForgeClient: merge_pr ##{index} — 405 whose MESSAGE reads transient, but the PR " <>
                "state still reports `mergeable: false`: no retry. The cause is CLASSIFIED " <>
                "upstream (`MergeOutcome`), not here. body=#{inspect(body)}"
            )

            {:error, {:merge_blocked, body}}

          false ->
            do_merge_retry(config, repo, index, method, delay, attempts_left, body, err)
        end

      {:error, _} = err ->
        err
    end
  end

  # ⚠ CECI N'EST PAS UNE CLASSIFICATION, ET LA DISTINCTION EST TOUT LE SOIN DE CE BLOC.
  #
  # `Fleet.Pilot.MergeOutcome` est l'autorite qui dit ce qu'un echec de merge EST — conflit, brouillon,
  # politique, deja fusionne, inconnu — et elle reste seule a le dire : la frontiere interdit d'ici
  # de l'appeler, et c'est tant mieux, parce qu'un second classificateur donnerait un second avis.
  # Le rail de routage la consulte deja apres coup (`Remediation.route_merge_failure`).
  #
  # Ce qu'on lit ici est UN BIT, et il ne sert qu'a une chose : decider s'il vaut la peine de
  # REESSAYER. « La forge se dit encore non-fusionnable » ne nomme aucune cause ; elle dit seulement
  # que retenter dans 800 ms n'y changera rien. Un brouillon y tombe aussi, et c'est correct : le
  # retenter est tout aussi vain.
  #
  # LA LECTURE RATEE VAUT `false`, jamais `true`. Se tromper de ce cote-la coute une tentative de
  # plus ; se tromper de l'autre transformerait un transitoire en blocage annonce sur une forge qui
  # n'a simplement pas repondu.
  defp still_unmergeable?(config, repo, index) do
    case http_get(config, "/repos/#{encode_repo(repo)}/pulls/#{index}") do
      {:ok, %{"mergeable" => false}} -> true
      _ -> false
    end
  end

  @doc false
  # Le diagnostic du refus : transitoire (on retente) ou reel (on abandonne).
  @spec do_merge_retry(
          term(),
          String.t(),
          integer(),
          String.t(),
          non_neg_integer(),
          pos_integer(),
          term(),
          term()
        ) ::
          :ok | {:error, term()}
  def do_merge_retry(config, repo, index, method, delay, attempts_left, body, err) do
    if attempts_left > 1 and merge_checking?(body) do
      Logger.info(
        "ForgeClient: merge_pr ##{index} mergeability in progress ('try again later') → " <>
          "retry in #{delay}ms (#{attempts_left - 1} remaining)"
      )

      Process.sleep(delay)
      do_merge(config, repo, index, method, delay, attempts_left - 1)
    else
      # DEUX SILENCES DANS UN SEUL `else`, et le premier est le plus cher.
      #
      # Gitea rend `405` pour deux faits opposes : « la mergeabilite est encore en cours de
      # calcul » (transitoire, il faut reessayer) et « cette PR n'est pas fusionnable »
      # (definitif : conflits, controles en echec). Rien de STRUCTURE ne les separe dans la
      # reponse recue — seul le libelle anglais le fait, `"try again later"`. La detection
      # textuelle reste donc, faute d'autre chose, mais elle ne peut plus DEGRADER EN SILENCE :
      # le jour ou Gitea reformule ce message, tout `405` devient « definitif », les merges
      # echouent, et rien ne disait pourquoi — seule la branche RECONNUE ecrivait au journal.
      #
      # Le corps entier est journalise, et c'est delibere : il est a la fois le diagnostic du
      # jour et la matiere du jour ou un champ structure apparaitra. On ne peut pas affirmer
      # qu'il n'en existe pas — on peut faire en sorte de le voir arriver.
      _ =
        if merge_checking?(body) do
          Logger.warning(
            # ⚠ CE MESSAGE CITAIT `@merge_checking_retries`, l'attribut du CLIENT, alors que le
            # budget arrive ICI en PARAMETRE. Les deux valaient 3, donc rien ne se voyait — mais
            # changer le budget au site d'appel aurait fait mentir le message. Il nomme desormais
            # ce qu'il sait ; le compte exact vit dans les `info` de reprise ci-dessus.
            "ForgeClient: merge_pr ##{index} — mergeability still computing after the configured " <>
              "retry budget, giving up: #{inspect(body)}"
          )
        else
          Logger.warning(
            "ForgeClient: merge_pr ##{index} — HTTP 405 NOT recognised as transient " <>
              "(no \"try again later\" in the message) → treated as DEFINITIVE. If Gitea " <>
              "reworded it, this line is the only thing that says so: #{inspect(body)}"
          )
        end

      err
    end
  end

  defp merge_checking?(body) when is_map(body),
    do: body |> Map.get("message", "") |> String.downcase() |> String.contains?("try again later")

  defp merge_checking?(_), do: false

  @doc false
  # Retire la branche de tete apres fusion, en respectant l'espacement d'ecriture.
  @spec delete_head_branch_spaced(Transport.config(), String.t(), integer()) :: :ok
  def delete_head_branch_spaced(config, repo, index) do
    with {:ok, pr} <- http_get(config, "/repos/#{encode_repo(repo)}/pulls/#{index}"),
         head_ref when is_binary(head_ref) and head_ref != "" <- get_in(pr, ["head", "ref"]) do
      Fleet.Forge.WriteSpacing.gap()

      case http_delete(config, "/repos/#{encode_repo(repo)}/branches/#{encode_seg(head_ref)}") do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "ForgeClient: post-merge delete of #{head_ref} failed (#{inspect(reason)}) — dead branch survives"
          )
      end
    else
      other ->
        Logger.warning(
          "ForgeClient: post-merge head.ref unreadable for #{repo}##{index} (#{inspect(other)}) — branch not deleted"
        )
    end

    :ok
  end
end

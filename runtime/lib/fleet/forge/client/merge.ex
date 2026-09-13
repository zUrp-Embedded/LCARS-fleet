defmodule Fleet.Forge.Client.Merge do
  @moduledoc """
  Fusion, reprise bornee et nettoyage de branche, internes a `Fleet.Forge.Client`.
  Un 405 declenche une lecture de `mergeable` : false bloque la reprise ; toute autre
  reponse laisse le message du refus et le budget decider. La cause releve en amont
  de `Fleet.Pilot.MergeOutcome`, hors de cette boundary.
  """

  alias Fleet.Forge.Client.Transport

  require Logger

  import Fleet.Forge.Client.Transport, only: [http_get: 2, http_post: 3, http_delete: 2]

  import Fleet.Forge.Client.UrlSafe, only: [encode_repo: 1, encode_seg: 1]

  @doc false
  # Toute reponse HTTP reussie lance le nettoyage ; aucune relecture ne confirme le merge.
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
    # Cle du contrat MergePullRequestOption : "do" ; "Do" dependait de la tolerance Go.
    case http_post(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/merge", %{
           "do" => method
         }) do
      {:ok, _} ->
        delete_head_branch_spaced(config, repo, index)
        :ok

      {:error, {:http, 405, body}} = err ->
        # Bench fleet/probe-rails#24, 2026-08-18 : un conflit git reel rendait aussi
        # "Please try again later". Le texte seul avait provoque des reprises repetees.
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

  # Une lecture echouee ou une autre forme vaut false pour permettre la reprise,
  # sans prouver la fusion possible. Le bit ne classe pas la cause ni sa duree.
  defp still_unmergeable?(config, repo, index) do
    case http_get(config, "/repos/#{encode_repo(repo)}/pulls/#{index}") do
      {:ok, %{"mergeable" => false}} -> true
      _ -> false
    end
  end

  @doc false
  # Reprend si budget > 1 et sous-chaine "try again later" (casse ignoree).
  # Un champ message present mais non binaire leve ; delay n'est pas valide ici.
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
      # Distingue budget epuise et texte inconnu pour rendre une reformulation visible.
      # Le log dit DEFINITIVE, mais l'heuristique ne prouve pas la permanence du refus.
      _ =
        if merge_checking?(body) do
          Logger.warning(
            # Budget fourni par l'appelant, pas necessairement le defaut du client.
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
  # Supprime head.ref dans repo apres WriteSpacing.gap(), sans verifier le depot de tete.
  # Les erreurs retournees sont journalisees puis :ok ; une exception peut encore remonter.
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

defmodule Fleet.Forge.Client.Signing do
  @moduledoc """
  Deduplication par marqueur et login d'auteur, interne a `Fleet.Forge.Client`.
  La « signature » est une sous-chaine du corps, pas une signature cryptographique.
  Le retour vers `Fleet.Forge.Client.role_login/2` reste dans la meme boundary.
  """

  alias Fleet.Forge.Client.Transport

  require Logger

  import Fleet.Forge.Client.Transport, only: [paginate: 3, forge_bot_login: 2]

  import Fleet.Forge.Client.UrlSafe, only: [encode_repo: 1]

  @doc false
  # Lecture/identite systeme invérifiable => avertit et retourne false pour permettre le POST.
  @spec signed_or_warn(Transport.config(), String.t(), integer(), String.t(), keyword()) ::
          boolean()
  def signed_or_warn(config, repo, issue_number, sig, opts) do
    case comment_signed?(config, repo, issue_number, sig, opts) do
      {:ok, signed?} ->
        signed?

      {:unverified, why} ->
        Logger.warning(
          "ForgeClient: dedup NOT verified on #{repo}##{issue_number} (#{inspect(why)}) — posting " <>
            "anyway (refusing would drop a legitimate comment), but this marker may be a DUPLICATE. " <>
            "These signatures are business-bearing (rounds budget, seal, escalation), so the cost " <>
            "lands elsewhere and later: signature=#{inspect(sig)}"
        )

        false
    end
  end

  # Distinguer absence et lecture impossible permet de signaler le risque de doublon
  # (budget de rounds, sceau, escalade) sans supprimer une publication legitime.
  defp comment_signed?(config, repo, issue_number, sig, opts) do
    case paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      {:ok, comments} when is_list(comments) ->
        case trusted_comments(comments, config, opts) do
          {:unverified, _} = unverified ->
            unverified

          {:ok, list} ->
            {:ok, Enum.any?(list, &String.contains?(&1["body"] || "", sig))}
        end

      other ->
        {:unverified, {:comments_unreadable, other}}
    end
  end

  # dedup_any_author saute la resolution des identites : un tiers peut alors inhiber le POST.
  defp trusted_comments(comments, config, opts) do
    if Keyword.get(opts, :dedup_any_author, false) do
      {:ok, comments}
    else
      # Systeme et role demande, pour retrouver aussi les publications sous compte de role.
      keep_trusted(comments, trusted_logins(config, opts))
    end
  end

  defp keep_trusted(comments, {:ok, logins}),
    do: {:ok, Enum.filter(comments, fn c -> get_in(c, ["user", "login"]) in logins end)}

  defp keep_trusted(_comments, {:error, why}), do: {:unverified, {:trusted_logins, why}}

  @doc false
  # Les logins autorises a poser un marqueur que le runtime relira.
  @spec trusted_logins(Transport.config(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def trusted_logins(config, opts) do
    with {:ok, bot} <- forge_bot_login(config, opts) do
      with_role_login(bot, Keyword.get(opts, :dedup_role), opts)
    end
  end

  defp with_role_login(bot, role, opts) when is_binary(role) do
    case Fleet.Forge.Client.role_login(role, opts) do
      {:ok, login} -> {:ok, [bot, login]}
      # Toute erreur de resolution du role garde silencieusement le systeme seul.
      {:error, _} -> {:ok, [bot]}
    end
  end

  defp with_role_login(bot, _role, _opts), do: {:ok, [bot]}
end

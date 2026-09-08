defmodule Fleet.Forge.Client.Signing do
  @moduledoc """
  La signature des commentaires : qui a le droit d'ecrire un marqueur que le runtime relira.

  Un marqueur de protocole pose en commentaire est une INSTRUCTION pour la machine a etats. S'il
  suffisait d'ecrire le texte pour qu'il compte, n'importe quel compte de la forge pourrait piloter
  le rail depuis un commentaire. La signature est ce qui distingue un marqueur POSE PAR LE SYSTEME
  d'un marqueur qu'un humain a recopie.

  `trusted_logins/2` appelle `Fleet.Forge.Client.role_login/3`, qui reste sur le client : c'est un
  cycle d'appel entre deux modules d'une meme boundary, prefere a un deplacement qui toucherait la
  surface publique.

  ⚠ AUCUNE DE CES FONCTIONS N'EST DANS LA COUTURE : l'API atteinte par `forge().x` reste
  entierement sur `Fleet.Forge.Client`, ce module ne porte que de la machinerie. Publiques parce
  qu'elles traversent une frontiere de module, `@doc false` le dit.
  """

  alias Fleet.Forge.Client.Transport

  require Logger

  import Fleet.Forge.Client.Transport, only: [paginate: 3, forge_bot_login: 2]

  import Fleet.Forge.Client.UrlSafe, only: [encode_repo: 1]

  @doc false
  # Le commentaire est-il signe par un compte de confiance — sinon on le dit.
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

  # ⚠ UN `false` NU DIRAIT DEUX CHOSES : « lu, aucun marqueur » et « pas pu lire ». Les deux menent
  # a poster — l'arbitrage est ecrit dans le `@doc` de `post_comment/4` (« If the bot identity or
  # comment history cannot be resolved, no existing marker is trusted and the comment is posted »)
  # et il NE CHANGE PAS : refuser de poster sur une lecture ratee supprimerait un commerce legitime.
  # Mais ces marqueurs sont METIER — budget de rounds, sceau, escalade — donc un doublon a un cout
  # ailleurs, plus tard, et loin d'ici. Rendre le doute distinct est ce qui permet de le NOMMER au
  # moment ou il naît ; c'est le seul endroit ou la correlation existe encore.
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

  # Counted markers trust the system author; observability markers may opt into any author.
  defp trusted_comments(comments, config, opts) do
    if Keyword.get(opts, :dedup_any_author, false) do
      {:ok, comments}
    else
      # Les comptes que le daemon DETIENT : le systeme, plus le role sous lequel l'appelant ecrit
      # quand il le declare (`:dedup_role`). Elargir a « n'importe quel auteur » laisserait un tiers
      # SUPPRIMER un commentaire legitime en postant sa signature en premier ; s'y limiter rendrait
      # la dedup aveugle a tout ce qui est signe par un role, c'est-a-dire a la quasi-totalite de ce
      # qu'elle garde.
      keep_trusted(comments, trusted_logins(config, opts))
    end
  end

  defp keep_trusted(comments, {:ok, logins}),
    do: {:ok, Enum.filter(comments, fn c -> get_in(c, ["user", "login"]) in logins end)}

  # LA LECTURE A REUSSI, LES IDENTITES NON. Rendre `[]` ici dirait « aucun commentaire de
  # confiance », c'est-a-dire « pas de marqueur » — alors qu'on ne sait pas QUI a ecrit quoi.
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
      # Le role n'a pas de jeton ici : on garde le systeme seul plutot que d'echouer une
      # publication pour une question de dedup.
      {:error, _} -> {:ok, [bot]}
    end
  end

  defp with_role_login(bot, _role, _opts), do: {:ok, [bot]}
end

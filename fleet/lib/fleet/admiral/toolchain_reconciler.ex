defmodule Fleet.Admiral.ToolchainReconciler do
  @moduledoc """
  Le déclencheur du rail d'outillage — et ce n'est pas un événement, c'est une COMPARAISON.

  DOMAINE, PAS PILOT : converger la boîte est du system-side (le métier de ce domaine), pas de la
  conduite de projet. Une v1 vivait dans `Fleet.Pilot` avec sa propre plomberie de tick — le
  domaine portait déjà `PeriodicCheck`, gardé « pour le prochain check périodique » : le voici.
  La plomberie (start_link nommé, tick + re-arm EN DERNIER, hook `:check_now` qui rejoue le chemin
  complet SANS re-armer) vit là-bas ; ce module garde son état, son `do_check/1` et la forme de sa
  réponse.

  ## Pourquoi rien n'écoute le merge

  `CLAUDE.md` le pose pour toute la fleet : *« le webhook `gitea.*` est un ACCÉLÉRATEUR de poll,
  jamais une source de vérité »* — et `gitea.merged` est déclaré **sans consommateur** dans
  `priv/event_router/events.yaml`. Ce module lit donc le head de la branche protégée et le
  compare au dernier SHA qu'il a appliqué. Ils diffèrent ⇒ il converge.

  Trois propriétés tombent gratuitement, et c'est ce qui rend la comparaison meilleure qu'un
  abonnement :

    * **le boot n'est pas un cas spécial.** C'est un tick comme un autre. Forge injoignable au
      démarrage ⇒ le tick suivant réessaie, au lieu d'un no-op silencieux qu'aucun rejeu ne rattrape.
    * **une PR fermée sans merge ne laisse rien de pendant** côté branche : le SHA n'a pas bougé,
      il n'y a rien à réconcilier. (Côté work-item, elle laisse un verrou — cf. le cycle de vie,
      `01` §7.3.)
    * **rejouer est sans effet.** Deux invocations voient le même écart et font le même geste.

  ## Le rebuild, et pourquoi le marqueur vit AVEC LE CONTENEUR

  Le marqueur (`toolchain.applied`) décrit pour moitié l'état de `/usr`, qui meurt avec le
  conteneur. Il vit donc sous `LCARS_TOOLCHAIN_RUN_STATE` — défaut `/run/lcars/toolchain`, un
  **tmpfs** : il meurt avec le conteneur PAR CONSTRUCTION, même motif que
  `/run/lcars-provision.rc` (« le fichier décrit TOUJOURS ce boot-ci »). JAMAIS sur le magasin ni
  sous un chemin qu'un volume pourrait recouvrir : une v2 le posait en `/var/lib/lcars/toolchain`
  pendant que le convergeur défaute son STORE sur `/var/lib/lcars` — si le lot F montait le
  magasin là, le marqueur « conteneur » aurait survécu au rebuild et la boîte se serait dite à
  jour sur un /usr nu (le défaut de `b341f415f`, ré-ouvert par collision de défauts — audit).
  Posé 2775 root:fleet par `45-sudoers-toolchain` à chaque boot. Après un rebuild, le marqueur
  est mort ⇒ le premier tick reconverge — c'est le mécanisme qui remplace l'ancien « convergeur
  dans la séquence d'entrypoint » de `01` §4.5.

  ## Ce qu'il n'est pas

  Il n'installe rien. Il constate un écart et appelle **un** binaire root, dont l'entrée est un
  manifeste déjà mergé sur une branche protégée. Le seul geste privilégié de tout le rail tient
  dans cette invocation, et son argument a été signé par un humain avant d'exister.

  ## Configuration

    * `:lcars_fleet, :admiral_toolchain_reconcile_interval_ms` — défaut `60_000`
    * `:lcars_fleet, :forge_client` — seam de lecture (`branch_head/3`)
    * `:lcars_fleet, :toolchain_converger` — seam du geste (défaut : une demande sur
      `toolchain.sock`, servie par `lcars-privileged`). Rend `{:ok, sha_appliqué}` ou
      `{:error, cause}` ; `:ok` nu reste accepté pour les doublures de témoins.
    * `:lcars_fleet, :toolchain_socket` — défaut `/run/lcars/privileged/toolchain.sock`

  ⚠ `:toolchain_converger_bin` A DISPARU AVEC LE `sudo` QUI LE NOMMAIT. Ce module ne désigne plus
  aucun binaire : il ne dit pas QUOI exécuter, ni sur QUOI — il ouvre une socket, et c'est le
  service privilégié qui résout la tête de la branche protégée. Le nom du binaire vit chez lui,
  qui est le seul à l'invoquer.
  """

  use GenServer

  require Logger

  alias Fleet.Admiral.PeriodicCheck

  @default_interval_ms 60_000
  @default_run_state "/run/lcars/toolchain"

  # ⚠ DEUX DÉLAIS, ET ILS NE MESURENT PAS LA MÊME CHOSE. Ouvrir une socket unix locale est
  # instantané ou impossible — cinq secondes suffisent, et au-delà c'est que l'unité ne répond pas.
  # La CONVERGENCE, elle, installe des paquets : elle dure des minutes. Un délai unique aurait forcé
  # à choisir entre « une porte morte fait attendre un quart d'heure » et « un `apt` normal est tué
  # en plein vol », et le second se lit comme un convergeur cassé.
  @socket_connect_ms 5_000
  @converge_timeout_ms 30 * 60_000

  # ── API ─────────────────────────────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: PeriodicCheck.start_link(__MODULE__, opts)

  @doc """
  Joue une passe MAINTENANT — le hook `:check_now` de `PeriodicCheck` : le MÊME chemin que le
  tick, sans re-armer (un appel hors-bande ne décale pas la cadence).

  C'est la porte de l'opérateur après un merge, et celle des témoins. Rend ce que la passe a
  conclu : `{:ok, :converged, sha}` | `{:ok, :up_to_date}` | `{:error, term}`.
  """
  @spec check_now(GenServer.server()) ::
          {:ok, :converged, String.t()} | {:ok, :up_to_date} | {:error, term()}
  def check_now(server \\ __MODULE__), do: GenServer.call(server, :check_now)

  @doc """
  Le SHA appliqué sur ce CONTENEUR, ou `nil` si le convergeur n'est jamais passé depuis son boot.

  ⚠ **`nil` ET « à jour » NE SONT PAS LA MÊME CHOSE**, et les confondre est le piège que ce fichier
  existe pour éviter : une boîte neuve (ou REBUILDÉE — le marqueur meurt avec le conteneur, c'est
  voulu) n'a rien appliqué, donc son premier tick DOIT converger même si la branche n'a pas bougé.
  """
  @spec applied_sha() :: String.t() | nil
  def applied_sha do
    case File.read(marker_path()) do
      {:ok, sha} -> String.trim(sha) |> nil_if_empty()
      {:error, _} -> nil
    end
  end

  # ── GenServer (la plomberie est à PeriodicCheck, pas ici) ───────────────────────────────────

  @impl GenServer
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms) || config_interval(),
      repo: Keyword.get(opts, :repo),
      branch: Keyword.get(opts, :branch),
      last_result: nil,
      rejected_sha: nil
    }

    _ = PeriodicCheck.schedule(:reconcile, state.interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:reconcile, state), do: PeriodicCheck.tick(state, :reconcile, &do_check/1)
  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:check_now, _from, state),
    do: PeriodicCheck.check_now(state, &do_check/1, & &1.last_result)

  # ── la passe ────────────────────────────────────────────────────────────────────────────────

  # LOSSY PAR CONSTRUCTION : une passe qui lève ne doit pas tuer le rail — mais le re-arm de
  # `PeriodicCheck.tick` est EN DERNIER, donc une passe qui lève arrêterait le timer. D'où le
  # rescue ICI, dans le do_check : la forge tombe, un disque est plein, le binaire root sort
  # non-zéro — le tick suivant réessaiera.
  defp do_check(state) do
    result =
      try do
        reconcile_pass(state)
      rescue
        e ->
          Logger.error("ToolchainReconciler: passe en échec — #{Exception.message(e)}")
          {{:error, {:raised, Exception.message(e)}}, state.rejected_sha}
      end

    %{state | last_result: elem(result, 0), rejected_sha: elem(result, 1)}
  end

  # Rend `{résultat, sha_refusé}` — LE SHA REFUSÉ EST COLLANT (audit 2026-08-19) : un convergeur
  # qui sort 2 dit « ce DOCUMENT est faux, un humain corrige ». Sans mémoire, la comparaison
  # revoyait le même écart au tick suivant et rebouclait toutes les 60 s sur une faute qu'aucun
  # rejeu ne répare — en re-téléchargeant l'installeur à chaque tour. Le gel se PURGE dès que la
  # branche bouge : le head suivant est un autre document, il a droit à sa chance.
  defp reconcile_pass(state) do
    repo = state.repo || Fleet.Toolchain.ops_repo()
    branch = state.branch || Fleet.Toolchain.branch()

    {result, rejected} =
      case forge().branch_head(repo, branch, []) do
        {:ok, head} when head == state.rejected_sha ->
          Logger.debug(
            "ToolchainReconciler: head #{head} déjà REFUSÉ (document faux) — gelé jusqu'à un " <>
              "nouveau merge"
          )

          {{:error, {:manifest_rejected, head}}, head}

        {:ok, head} ->
          case converge_if_moved(head) do
            {:error, {:converger_failed, 2, _out}} = err ->
              Logger.error(
                "ToolchainReconciler: le convergeur a JUGÉ LE DOCUMENT FAUX (rc=2) à #{head} — " <>
                  "gelé : aucun rejeu ne répare un manifeste refusé, seul un nouveau merge dégèle"
              )

              {err, head}

            other ->
              {other, nil}
          end

        {:error, reason} ->
          # Une forge injoignable ne PURGE pas le gel : on n'a rien appris sur la branche.
          {unreachable(reason), state.rejected_sha}
      end

    drain_pass(repo, branch, result)
    {result, rejected}
  end

  # ── LA SECONDE PASSE, ET ELLE N'EST PAS OPTIONNELLE (`01` §7.3) ──────────────────────────────
  #
  # Une PR fermée SANS merge ne fait pas bouger la branche : la comparaison de head ne la verra
  # JAMAIS. Sans cette passe, le work-item attend un événement qui n'arrivera pas — indistinguable
  # d'un work-item en cours, l'ambiguïté que tout le rail refuse.
  #
  # STATELESS : le VERROU (`lcars-awaits-toolchain` sur l'issue) est l'état, la forge le porte.
  # Une PR déjà drainée n'a plus le verrou ⇒ aucun geste, aucune re-annonce. Et le drain d'une PR
  # MERGÉE est gaté sur « la branche est appliquée » (`:up_to_date` ou `:converged` de CETTE
  # passe) : re-dispatcher un work-item AVANT que sa toolchain soit posée le renverrait au mur.
  # Une PR REFUSÉE se draine sans condition — il n'y a rien à attendre.
  #
  # LOSSY : un échec de liste ou de drain se dit et n'altère pas le résultat de branche — le tick
  # suivant retentera (le verrou est toujours là).
  defp drain_pass(repo, branch, branch_result) do
    # UNE passe paginee, filtree `base=` COTE SERVEUR (`/pulls?state=all&base=`) — la v1 passait
    # par list_pulls/2 : toutes les PR de la boite + un GET par PR, toutes les 60 s (audit).
    case forge().list_pulls_for_base(repo, branch, []) do
      {:ok, prs} ->
        Enum.each(prs, &maybe_drain(&1, branch, branch_result))

      {:error, reason} ->
        Logger.warning(
          "ToolchainReconciler: passe de drain — PR illisibles (#{inspect(reason)}), " <>
            "les verrous restent posés, le tick suivant retentera"
        )
    end
  rescue
    e ->
      Logger.warning("ToolchainReconciler: passe de drain en échec — #{Exception.message(e)}")
  end

  defp maybe_drain(pr, branch, branch_result) do
    # Ceinture : le serveur a filtre `base=`, on re-verifie quand meme (un double de test ou une
    # forge exotique pourraient rendre plus large).
    with true <- pr["base"]["ref"] == branch,
         {:ok, item_repo, item_issue} <- Fleet.Toolchain.parse_workitem_marker(pr["body"]) do
      case pr_outcome(pr) do
        :open ->
          :ok

        :merged ->
          if applied?(branch_result),
            do: drain(item_repo, item_issue, pr, :merged),
            else: :ok

        :refused ->
          drain(item_repo, item_issue, pr, :refused)
      end
    else
      # Une PR vers la branche protégée SANS marqueur n'est pas à nous (posée à la main) ; une PR
      # d'une autre base n'est pas du rail. Ni geste ni bruit.
      _ -> :ok
    end
  end

  defp pr_outcome(pr) do
    cond do
      pr["merged"] == true -> :merged
      pr["state"] == "closed" -> :refused
      true -> :open
    end
  end

  defp applied?({:ok, :up_to_date}), do: true
  defp applied?({:ok, :converged, _}), do: true
  defp applied?(_), do: false

  defp drain(repo, issue, pr, why) do
    lock = Fleet.Toolchain.waiting_label()

    case forge().get_issue(repo, issue, []) do
      {:ok, %{"labels" => labels}} ->
        if Enum.any?(labels || [], &(&1["name"] == lock)) do
          do_drain(repo, issue, pr, why, lock)
        else
          :ok
        end

      {:ok, _shape} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ToolchainReconciler: drain — issue #{repo}##{issue} illisible (#{inspect(reason)}), " <>
            "le verrou reste, le tick suivant retentera"
        )
    end
  end

  defp do_drain(repo, issue, pr, why, lock) do
    case forge().remove_label(repo, issue, lock, []) do
      {:ok, _} ->
        # Le retrait du verrou EST le re-dispatch : `StepDispatcher.decide/1` cesse de sauter
        # l'issue, le poller la re-propose au tick suivant. Le commentaire est le POURQUOI humain.
        _ = forge().post_comment(repo, issue, drain_comment(why, pr), [])

        Logger.info(
          "ToolchainReconciler: work-item #{repo}##{issue} drainé (#{why}, PR ##{pr["number"]})"
        )

      {:error, reason} ->
        Logger.warning(
          "ToolchainReconciler: drain — verrou de #{repo}##{issue} non retiré " <>
            "(#{inspect(reason)}), le tick suivant retentera"
        )
    end
  end

  defp drain_comment(:merged, pr) do
    "Outillage APPLIQUÉ : la PR ##{pr["number"]} est mergée et la boîte a convergé. " <>
      "Ce ticket redevient dispatchable."
  end

  defp drain_comment(:refused, pr) do
    "Demande d'outillage REFUSÉE : la PR ##{pr["number"]} a été fermée sans merge. " <>
      "Ce ticket redevient dispatchable — à l'humain du projet de décider la suite " <>
      "(autre approche, ou re-demande amendée)."
  end

  defp converge_if_moved(head) do
    case applied_sha() do
      ^head ->
        {:ok, :up_to_date}

      previous ->
        Logger.info(
          "ToolchainReconciler: écart détecté (appliqué=#{previous || "aucun"} head=#{head}) — convergence"
        )

        run_converger(head)
    end
  end

  # LE SHA N'EST NOTÉ QU'APRÈS UN SUCCÈS, et jamais avant. L'inverse — noter puis appliquer — ferait
  # d'un convergeur mort en route une boîte qui se croit à jour : le tick suivant verrait « pas
  # d'écart » et l'état approuvé resterait non appliqué, en silence, ce que tout ce rail refuse.
  # ⚠ LE MARQUEUR PORTE LE SHA QUE LE SERVICE A APPLIQUÉ, PAS CELUI QU'ON AVAIT LU.
  #
  # Entre notre lecture de la tête et la résolution que le service fait de son côté, la branche a pu
  # avancer — le rail EXISTE pour que des PR y atterrissent. Noter notre tête ferait croire la boîte
  # à jour sur un état qu'elle n'a pas appliqué, et le tick suivant ne verrait AUCUN écart : la
  # panne muette exacte que tout le reste de ce module refuse.
  #
  # `:ok` NU EST ENCORE ACCEPTÉ, et c'est pour les doublures de témoins qui ne rendent pas de SHA.
  # Sur ce chemin le marqueur retombe sur la tête lue — correct pour un double, jamais atteint par
  # le service réel, qui répond toujours `OK:<sha>`.
  defp run_converger(head) do
    case converger().(head, []) do
      {:ok, applied} when is_binary(applied) and applied != "" ->
        if applied != head do
          Logger.info(
            "ToolchainReconciler: la branche a avancé entre la lecture (#{head}) et la " <>
              "convergence (#{applied}) — c'est l'état APPLIQUÉ qui est noté."
          )
        end

        _ = write_marker(applied)
        {:ok, :converged, applied}

      :ok ->
        _ = write_marker(head)
        {:ok, :converged, head}

      {:error, reason} ->
        Logger.error(
          "ToolchainReconciler: le convergeur a REFUSÉ #{head} (#{inspect(reason)}) — le SHA " <>
            "appliqué reste inchangé, la passe suivante réessaiera. L'état déclaré n'est PAS appliqué."
        )

        {:error, reason}
    end
  end

  # L'UNIQUE GESTE PRIVILÉGIÉ DU RAIL. `sudo` sur UN binaire nommé (cf. le sudoers étroit,
  # `45-sudoers-toolchain`), jamais un shell : la ligne de commande ne porte que le SHA, et le
  # convergeur lit le manifeste à ce SHA depuis la forge.
  #
  # ⚠ « SON ARGUMENT A ÉTÉ SIGNÉ » N'EST PAS UNE PROPRIÉTÉ DE CET APPEL, et l'avoir écrit ici comme
  # telle a masqué un chemin `groupe → root` aussi longtemps que la phrase est restée. Le sudoers
  # ouvre ce binaire à TOUT `%fleet` — que `human-converger` peuple depuis la team `humans` de la
  # forge, toutes les 30 s — donc n'importe lequel de ses membres l'appelle sans passer par ici.
  # La propriété est tenue EN AVAL : le convergeur refuse désormais tout SHA qui n'est pas la tête
  # de `tool_request`. C'est là qu'elle vit, et là qu'elle se casse si on la retire.
  defp default_converger(_head, _opts) do
    path =
      Application.get_env(:lcars_fleet, :toolchain_socket) ||
        System.get_env("LCARS_TOOLCHAIN_SOCKET") ||
        "/run/lcars/privileged/toolchain.sock"

    # ⚠ `{:local, path}` AVEC `0` EN PORT : la forme qu'Erlang exige pour AF_UNIX. Le zéro n'est pas
    # un port — même idiome que `Fleet.Credentials.Authority` et le listener d'événements.
    opts = [:binary, packet: :line, active: false]

    case :gen_tcp.connect({:local, path}, 0, opts, @socket_connect_ms) do
      {:ok, sock} ->
        try do
          read_converge_answer(sock, path)
        after
          :gen_tcp.close(sock)
        end

      {:error, reason} ->
        # LA PORTE FERMÉE ET LA PORTE GARDÉE NE SE DISENT PAS PAREIL. Une socket absente est un fait
        # SYSTÈME (l'unité ne tourne pas) ; un refus est une réponse. Les confondre envoie chercher
        # une autorisation manquante alors qu'il manque un service.
        {:error, {:privileged_unreachable, path, reason}}
    end
  end

  # ⚠ RIEN N'EST ÉCRIT SUR LE FIL. La socket dit le verbe, la forge dit le contenu : ouvrir la
  # connexion EST la demande. Un mot envoyé ici rouvrirait la seule surface par laquelle un appelant
  # pourrait influer sur ce que root exécute.
  defp read_converge_answer(sock, path) do
    case :gen_tcp.recv(sock, 0, @converge_timeout_ms) do
      {:ok, line} ->
        case String.trim_trailing(line, "\n") do
          "OK:" <> sha when byte_size(sha) > 0 ->
            {:ok, sha}

          "FAIL:" <> cause ->
            {:error, {:converger_refused, cause}}

          # ⚠ UNE LIGNE VIDE N'EST PAS UN SUCCÈS. Un service qui ferme avant de répondre rendrait
          # une chaîne vide ; la lire comme « appliqué » noterait un SHA jamais posé, et le tick
          # suivant ne verrait plus d'écart.
          other ->
            {:error, {:converger_mute, path, other}}
        end

      {:error, reason} ->
        {:error, {:converger_mute, path, reason}}
    end
  end

  # UNE FORGE INJOIGNABLE N'EST PAS UN ÉCART. Rendre `:up_to_date` ici ferait qu'une panne réseau
  # se lise comme « rien à faire » — et sur un rebuild, la boîte resterait sans outillage en
  # annonçant que tout va bien.
  defp unreachable(reason) do
    Logger.warning(
      "ToolchainReconciler: branche illisible (#{inspect(reason)}) — AUCUNE conclusion tirée, " <>
        "la passe suivante réessaiera. Ce n'est pas « à jour »."
    )

    {:error, {:branch_unreadable, reason}}
  end

  defp marker_path do
    dir =
      case System.get_env("LCARS_TOOLCHAIN_RUN_STATE") do
        d when is_binary(d) and d != "" -> d
        _unset -> @default_run_state
      end

    Path.join(dir, "toolchain.applied")
  end

  defp write_marker(head) do
    path = marker_path()
    _ = File.mkdir_p(Path.dirname(path))

    case File.write(path, head <> "\n") do
      :ok ->
        :ok

      {:error, reason} ->
        # Convergé mais sans mémoire : la passe suivante reconvergera (idempotent, donc correct) —
        # mais un tick qui refait le travail à CHAQUE passe doit se voir, pas passer pour un cycle
        # normal.
        Logger.warning(
          "ToolchainReconciler: convergé sur #{head} mais le marqueur est INÉCRIVABLE " <>
            "(#{inspect(reason)} sur #{path}) — la prochaine passe reconvergera. Le répertoire " <>
            "est posé par le provisioning (45-sudoers-toolchain)."
        )

        :ok
    end
  end

  defp config_interval,
    do:
      Application.get_env(
        :lcars_fleet,
        :admiral_toolchain_reconcile_interval_ms,
        @default_interval_ms
      )

  # ⚖ RENOMMEE LE 2026-08-21 : `:forge_client` -> `:admiral_forge_client`. Sa voisine juste
  # au-dessus porte deja le prefixe (`:admiral_toolchain_reconcile_interval_ms`) ; celle-ci etait
  # l'une des deux SEULES clefs de module du projet sans proprietaire, et le meme nom designait
  # ailleurs un mecanisme de portee differente (22 `Keyword.get(opts, :forge_client, …)` dans
  # `Pilot`, injection par appel). Motif complet dans `Fleet.MCP.PodTools.Probe`, section Coutures.
  defp forge, do: Application.get_env(:lcars_fleet, :admiral_forge_client, Fleet.Forge.Client)

  defp converger,
    do:
      Application.get_env(:lcars_fleet, :toolchain_converger, &__MODULE__.default_converger_fun/2)

  @doc false
  @spec default_converger_fun(String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error,
             {:converger_refused, binary()}
             | {:converger_mute, Path.t(), term()}
             | {:privileged_unreachable, Path.t(), term()}}
  def default_converger_fun(head, opts), do: default_converger(head, opts)

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s
end

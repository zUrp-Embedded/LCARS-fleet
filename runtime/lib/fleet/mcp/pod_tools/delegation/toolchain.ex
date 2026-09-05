defmodule Fleet.MCP.PodTools.Delegation.Toolchain do
  @moduledoc """
  TOOLCHAIN channel — a pod asks for a change to the fleet's own tooling, from inside the work
  item it is running.

  The address of the request is READ from the work item, never taken from the wire: a pod that
  could name its own target could ask for a change on someone else's rail.
  """

  require Logger

  alias Fleet.MCP.PodTools.Delegation.{ForgeWriter, Gate}

  @doc """
  Ouvre la demande d'outillage d'un pod bloqué : branche, manifeste, pull request.

  L'IDENTITÉ EST LE CANAL. `pod_id` vient de l'accepteur de socket (un pod, une socket) et le
  work-item s'en DÉDUIT — jamais d'un argument. Rien dans la demande ne nomme un ticket : il n'y a
  donc rien à prouver, la socket discrimine. C'est ce que `mix lcars.contracts.check` exige d'un
  outil MCP, et c'est aussi ce qui empêche un pod de demander au nom d'un autre.

  LECTURE PURE DU WORK-ITEM, et c'est un piège évité : `TaskQueue.get_for_pod/1` **mute** — il
  enregistre un poll et fait passer l'item de `:pending` à `:assigned` avec un broadcast. L'appeler
  ici émettrait une assignation fantôme et remettrait à zéro l'horloge de poll d'un pod qui, lui,
  n'a rien demandé de tel. `list_active/0` est une lecture, et les items actifs se comptent sur les
  doigts.

  DEUX CHEMINS, ET L'ABSENCE DE TICKET N'EST PLUS UN REFUS. Un pod qui bute sur l'outil manquant
  en cours de travail met son work-item en attente et le fait re-dispatcher ; un pod SANS work-item
  — l'architecte qui anticipe, ce pour quoi son cap-profile lui accorde cet outil — ouvre la même
  PR sans verrou, sans marqueur et sans re-dispatch. Le drain saute déjà une PR sans marqueur
  (`Toolchain.parse_workitem_marker/1`), donc le second chemin ne demande rien de neuf en aval.

  IDEMPOTENT PAR LA BRANCHE : son nom dérive du work-item, ou du pod quand il n'y en a pas — deux
  préfixes distincts, jamais un espace de noms partagé. Un second appel réécrit le même fichier sur
  la même branche au lieu d'ouvrir une deuxième pull request pour un seul besoin. Une branche déjà
  là n'est pas une erreur.
  """
  @spec request_toolchain(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def request_toolchain(args, pod_id) when is_map(args) and is_binary(pod_id) and pod_id != "" do
    with :ok <- Fleet.Toolchain.validate_form(args),
         {:ok, forge} <- Gate.conforming(ForgeWriter, ForgeWriter.resolved()) do
      case active_work_item(pod_id) do
        {:ok, work_item} -> toolchain_for_work_item(args, pod_id, work_item, forge)
        {:error, :no_active_work_item} -> toolchain_anticipated(args, pod_id, forge)
      end
    end
  end

  def request_toolchain(_args, _pod_id), do: {:error, :pod_id_required}

  # LE CHEMIN AVEC TICKET — un pod bute sur l'outil manquant EN COURS DE TRAVAIL. Son work-item est
  # mis en attente et re-dispatché quand l'outil atterrit ; ce sont le verrou et le marqueur qui le
  # portent, jamais la mémoire du runtime.
  defp toolchain_for_work_item(args, pod_id, work_item, forge) do
    repo = Fleet.Toolchain.ops_repo()
    base = Fleet.Toolchain.branch()
    branch = Fleet.Toolchain.branch_for(work_item.id)
    eco = args["ecosystem"]

    content =
      Fleet.Toolchain.render(args,
        issue: work_item.issue_id,
        role: work_item.role,
        work_item_id: work_item.id
      )

    # UNE BRANCHE DÉJÀ LÀ N'EST PAS UNE ERREUR : c'est le second appel du même besoin. On écrase
    # le manifeste et on laisse la PR existante porter le diff mis à jour.
    _ = forge.create_branch(repo, branch, base, [])

    # LE LIEN EST ÉCRIT SUR LA FORGE, DANS LES DEUX SENS, jamais en mémoire (`01` §7.3) :
    #   * le corps de la PR porte le work-item (`workitem_marker`) — c'est ce que la seconde
    #     passe du réconciliateur lit pour savoir QUEL ticket drainer quand la PR se ferme
    #     (une fermeture sans merge ne fait pas bouger la branche : sans ce marqueur, le
    #     work-item attendrait un événement qui n'arrivera jamais) ;
    #   * l'issue du work-item porte le verrou `lcars-awaits-toolchain` + le marqueur de PR —
    #     le dispatcher la SAUTE tant que le verrou est posé.
    # L'échec du VERROU est fatal (fail-loud, le pod ré-émet — toute la chaîne amont est
    # idempotente : branche réutilisée, put_file écrase, open_pr rend la PR existante sur 409).
    # Le COMMENTAIRE est best-effort : sa perte ne coûte que du contexte humain, le drain se key
    # sur le verrou et le marqueur de PR.
    with {:ok, item_repo, item_issue} <- workitem_address(pod_id, work_item),
         {:ok, _} <-
           forge.put_file(repo, Fleet.Toolchain.manifest_path(eco), content, branch: branch),
         {:ok, pr} <-
           forge.open_pr(repo, branch, base, "[toolchain] #{eco}",
             body:
               "Demande d'outillage — work-item `#{work_item.id}` (#{item_repo}##{item_issue}).\n" <>
                 Fleet.Toolchain.workitem_marker(item_repo, item_issue)
           ),
         {:ok, _} <- forge.add_label(item_repo, item_issue, Fleet.Toolchain.waiting_label(), []) do
      case forge.post_comment(
             item_repo,
             item_issue,
             "Demande d'outillage en vol : PR #{repo}!#{pr_number(pr)} — ce ticket attend la " <>
               "signature d'un admin (ou son refus).\n" <>
               Fleet.Toolchain.marker(pr_number(pr) || 0),
             []
           ) do
        {:ok, _} ->
          :ok

        {:error, why} ->
          Logger.warning(
            "Delegation: toolchain_request — commentaire de lien NON posé sur " <>
              "#{item_repo}##{item_issue} (#{inspect(why)}) ; le verrou et le marqueur de PR " <>
              "portent le drain, seule la lisibilité humaine est perdue"
          )
      end

      arm_auto_merge(forge, repo, pr)

      {:ok, %{"status" => "toolchain_requested", "ecosystem" => eco, "pr" => pr_number(pr)}}
    end
  end

  # UN CLIC ADMIN (⚖ user) : l'auto-merge est armé par le runtime, la signature humaine est
  # l'approbation, la forge merge seule. GATE sur config, DÉFAUT OFF — armé sans protection de
  # branche, « conditions remplies » voudrait dire TOUT DE SUITE : merge sans signature, convergeur
  # derrière. Le geste d'installation pose la protection ET la config ENSEMBLE.
  # Best-effort : un armement raté laisse le chemin deux-clics (approve puis merge à la main).
  #
  # FACTORISÉ parce qu'il est joué par les DEUX chemins de demande. Recopié, il dériverait — et la
  # copie qui dérive serait celle du chemin qu'on joue le moins, donc celle que personne ne verrait.
  defp arm_auto_merge(forge, repo, pr) do
    if Application.get_env(:lcars_fleet, :toolchain_auto_merge, false) do
      case forge.schedule_auto_merge(repo, pr_number(pr), []) do
        {:ok, _} ->
          :ok

        :ok ->
          :ok

        {:error, why} ->
          Logger.warning(
            "Delegation: toolchain_request — auto-merge NON armé sur ##{pr_number(pr)} " <>
              "(#{inspect(why)}) ; le chemin deux-clics reste (approve puis merge)"
          )
      end
    end

    :ok
  end

  # LE CHEMIN SANS TICKET — L'ANTICIPATION, et c'est l'usage au nom duquel l'architecte a reçu ce
  # grant : « l'arch peut demander un outillage AVANT que les producers butent dessus »
  # (`architect.yaml`). Refuser ici sur `:no_active_work_item` rendrait la capacité MORTE pour sa
  # seule raison d'être — un grant et une garde écrits sur des hypothèses opposées. Le mur
  # `toolchain.grant_reachable` (`lcars.contracts.check`) les confronte.
  #
  # CE QUI TOMBE ICI, ET POURQUOI CE N'EST PAS UNE PERTE : il n'y a AUCUN ticket à verrouiller ni à
  # re-dispatcher. Pas de `lcars-awaits-toolchain`, pas de commentaire de lien, pas de
  # `workitem_marker` — et le drain le sait DÉJÀ : `Toolchain.parse_workitem_marker/1` rend `:error`
  # sur un corps sans marqueur, et la seconde passe du réconciliateur saute cette PR. Le chemin sans
  # ticket ne demande donc rien de neuf en aval ; il demande de ne pas mentir en amont.
  #
  # LE CORPS DE LA PR LE DIT, et ce n'est pas de la décoration : un admin qui merge doit savoir
  # qu'il installe un outil et qu'il ne débloque personne. Une PR d'anticipation qui ressemblerait à
  # une PR de déblocage ferait attendre un re-dispatch qui n'arrivera jamais.
  defp toolchain_anticipated(args, pod_id, forge) do
    with {:ok, %{role: role}} <- Gate.resolve_identity(pod_id) do
      repo = Fleet.Toolchain.ops_repo()
      base = Fleet.Toolchain.branch()
      branch = Fleet.Toolchain.branch_for_pod(pod_id)
      eco = args["ecosystem"]

      content = Fleet.Toolchain.render(args, role: role)

      # Même idempotence que l'autre chemin : une branche déjà là est le second appel du même besoin.
      _ = forge.create_branch(repo, branch, base, [])

      with {:ok, _} <-
             forge.put_file(repo, Fleet.Toolchain.manifest_path(eco), content, branch: branch),
           {:ok, pr} <-
             forge.open_pr(repo, branch, base, "[toolchain] #{eco} (anticipation)",
               body:
                 "Demande d'outillage ANTICIPÉE — rôle `#{role}`, AUCUN ticket en attente.\n\n" <>
                   "Merger installe l'outil sur les conteneurs qui suivent cette branche. " <>
                   "Aucun work-item ne sera re-dispatché : il n'y en a pas."
             ) do
        arm_auto_merge(forge, repo, pr)
        {:ok, %{"status" => "toolchain_requested", "ecosystem" => eco, "pr" => pr_number(pr)}}
      end
    end
  end

  # L'ADRESSE du work-item (dépôt du projet + numéro d'issue) — les deux clés du verrou. Le repo
  # vient de l'IDENTITÉ du pod (le canal, jamais le wire) ; le numéro de son issue_id. Un work-item
  # sans issue rattachable n'a pas de ticket à verrouiller ni à re-dispatcher : refus typé, le pod
  # sait que sa demande n'est pas traçable.
  defp workitem_address(pod_id, work_item) do
    with {:ok, %{repo: repo}} when is_binary(repo) and repo != "" <-
           Gate.resolve_identity(pod_id),
         {:ok, n} <- Fleet.Toolchain.workitem_issue_number(work_item.issue_id) do
      {:ok, repo, n}
    else
      :error -> {:error, :work_item_issue_unparseable}
      {:ok, _} -> {:error, :pod_repo_unbound}
      {:error, _} = err -> err
    end
  end

  # Le work-item ACTIF de ce pod, en lecture seule. `:no_active_work_item` plutôt qu'un `nil` qui
  # laisserait la suite composer un manifeste sans traçabilité — une demande qu'aucun ticket ne
  # réclame est une demande que personne ne saura rattacher au merge.
  defp active_work_item(pod_id) do
    case Enum.find(Fleet.TaskQueue.list_active(), &(&1.pod_id == pod_id)) do
      nil -> {:error, :no_active_work_item}
      item -> {:ok, item}
    end
  end

  # Le client canonique rend le NUMERO nu ({:ok, integer}, 409 compris — cf. le @callback de
  # `ForgeWriter`). Accepter ici une map — ce qu'aucun writer reel ne rend — rend le double vert
  # pendant que la prod rend `"pr" => nil`.
  defp pr_number(n) when is_integer(n), do: n
  defp pr_number(_), do: nil
end

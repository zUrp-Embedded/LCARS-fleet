defmodule Fleet.Pilot.StepRunConsumer.VerdictCorrection do
  @moduledoc """
  UNE passe de correction pour un juge dont l'ENVELOPPE est invalide — avant de figer le ticket.

  Jumeau structurel de `ReviewLifecycle.VerdictException` (l'arbitrage de zone grise), et
  délibérément : même marqueur forge-natif qui borne à une passe, même drapeau d'auto-gating, même
  remise à l'architecte quand le barreau ne peut pas être gravi. Les deux échelles répondent à des
  questions différentes — « qui tranche une contradiction » contre « qui répare une sortie
  malformée » — et partagent leur FORME, ce qui rend chacune lisible à qui a appris l'autre.

  ## Ce que ça répare, et ce que ça ne répare PAS

  Le contrat de sortie d'un juge est schema-validé, fail-closed : un champ mal typé rend
  `"halt_invalid"` (`Verdict.gate_decision/1`) et le ticket est gelé vers l'architecte. C'est la
  bonne direction — jamais un `"continue"` sur un verdict malformé — mais c'est un couperet posé
  sur **la forme**, pas sur le fond.

  Le juge a lu le livrable, il a une opinion, et il l'a mal emballée. Le geler immobilise un humain
  pour un `details` qui est une chaîne au lieu d'un objet. Alors : une passe, une seule, où le juge
  reçoit **ce qui n'allait pas** et ré-emballe.

  ⚠ **Ce n'est PAS un rattrapage de fond.** Un juge qui n'a pas compris le livrable ne le
  comprendra pas mieux à la deuxième passe, et rien ici ne le lui redemande : la correction porte
  sur l'ENVELOPPE, et le brief de correction le dit.

  ## Pourquoi une passe et pas deux

  Le marqueur EST le budget, et il vit SUR LA FORGE (`[verdict-correction:issue-N`) plutôt que dans
  la mémoire du pilote : un redémarrage ne doit pas acheter une seconde passe, et un humain doit
  pouvoir voir sur le ticket que ce barreau a été dépensé. Au-delà, l'architecte — une sortie qui
  reste malformée après qu'on a dit exactement ce qui clochait n'est plus un problème de forme.

  ## Pourquoi le pod est encore là pour la recevoir

  Parce qu'**aucune fauche n'est déclenchée par la PRODUCTION d'un verdict, seulement par son
  INGESTION** — et une enveloppe refusée n'est pas ingérée. Le juge vit donc encore, avec le
  contexte que lui a coûté sa lecture du livrable, et c'est exactement ce que cette passe dépense.

  La règle vaut pour les deux familles de juges, et par deux chemins différents : un juge de PR
  serait fauché par `StepRunCompleter` à la pose de sa revue — qui n'a pas lieu ici ; un juge de
  GATE (scoper, gatekeeper) arrive par `apply_verdict` et n'a aucune faucheuse sur ce chemin.
  """

  require Logger

  alias Fleet.Pilot.StepRunConsumer.TerminalEscalation

  defmodule Seams do
    @moduledoc """
    Les six coutures dont cette passe a besoin, et pas le `state` entier.

    `@enforce_keys` sur les six : une couture oubliee doit refuser a la construction, pas rendre
    `nil` a l'appel — c'est le meme durcissement que `ReviewLifecycle.Ctx`.
    """
    @enforce_keys [:repo, :forge, :forge_opts, :task_queue, :spawner, :terminal]
    defstruct [:repo, :forge, :forge_opts, :task_queue, :spawner, :terminal]

    @typedoc "Le paquet de coutures de la passe de correction."
    @type t :: %__MODULE__{
            repo: String.t(),
            forge: module(),
            forge_opts: keyword(),
            task_queue: module(),
            spawner: module(),
            terminal: Fleet.Pilot.StepRunConsumer.TerminalEscalation.Seams.t()
          }
  end

  @doc """
  Demande UNE correction d'enveloppe au juge, ou escalade.

  `reason` est ce que la validation a refusé — il voyage jusqu'au juge, parce qu'une demande de
  correction qui ne dit pas ce qui clochait est une demande de deviner.
  """
  @spec request(pos_integer(), String.t(), term(), String.t(), Seams.t()) :: term()
  def request(n, role, reason, trace, %Seams{} = seams) do
    # AUTO-GATÉ, ET ÉTEINT PAR DÉFAUT — même raison que le barreau d'arbitrage : un mécanisme qui
    # n'a jamais tourné de bout en bout sur un banc est une hypothèse, pas un rail. Le chemin
    # désactivé n'est PAS un no-op silencieux : il NOMME le barreau non armé dans l'escalade, pour
    # qu'un architecte lisant le gel puisse distinguer « la passe a échoué » de « la passe n'est
    # pas armée sur ce conteneur ».
    if enabled?() do
      do_request(n, role, reason, trace, seams)
    else
      freeze(n, role, trace, :correction_pass_disabled, seams)
    end
  end

  defp enabled?, do: Application.get_env(:lcars_fleet, :pilot_verdict_correction_pass?, false)

  defp do_request(n, role, reason, trace, %Seams{} = seams) do
    marker = "[verdict-correction:issue-#{n}"

    case decision(seams.forge.count_comments_marked(seams.repo, n, marker, seams.forge_opts)) do
      :correct -> summon(n, role, reason, trace, seams)
      :escalate -> freeze(n, role, trace, :correction_pass_spent, seams)
    end
  end

  @doc false
  # PORTE PURE : une correction, puis l'architecte. Un compte ILLISIBLE escalade au lieu de
  # corriger — même direction que les deux autres échelles, et pour la même raison : ne pas savoir
  # combien de passes ont été dépensées ne doit JAMAIS en acheter une de plus.
  @spec decision({:ok, integer()} | {:error, term()}) :: :correct | :escalate
  def decision({:ok, spent}) when is_integer(spent) and spent < 1, do: :correct
  def decision(_), do: :escalate

  defp summon(n, role, reason, trace, %Seams{} = seams) do
    signature = "[verdict-correction:issue-#{n}:round-1]"

    body =
      "⚙ **Enveloppe de verdict refusée** — le `#{role}` a rendu un verdict dont la FORME ne " <>
        "valide pas (`gate-decision.json`) : #{describe(reason)}.\n\n" <>
        "Passe de correction unique : le juge est encore en vie, avec sa lecture du livrable, et " <>
        "il lui est demandé de RÉ-EMBALLER son verdict — pas de le refaire. Au-delà de cette " <>
        "passe, le ticket est remis à l'architecte.\n\n" <> signature

    comment_opts =
      seams.forge_opts
      |> Keyword.put(:dedup_signature, signature)
      |> Keyword.put(:dedup_any_author, true)

    case seams.forge.post_comment(seams.repo, n, body, comment_opts) do
      {:ok, _} ->
        enqueue_correction(n, role, reason, trace, seams)

      {:error, why} ->
        # LE MARQUEUR EST LE BUDGET. Ne pas réussir à le poser et corriger quand même achèterait un
        # nombre illimité de passes : chaque tick lirait zéro marqueur et redemanderait. Même
        # leçon, mot pour mot, que le barreau d'arbitrage.
        Logger.warning(
          "VerdictCorrection: #{seams.repo}##{n} marker NOT posted (#{inspect(why)}) — no " <>
            "correction requested (an unrecorded pass is an unbounded one)"
        )

        freeze(n, role, trace, {:correction_marker_unposted, why}, seams)
    end
  end

  # Le brief part au pod QUI EST DÉJÀ LÀ — c'est tout l'intérêt de la passe. `PodId.for_issue/3` :
  # ce juge-là a été minté sur le ticket (gate d'étape), pas sur une PR.
  defp enqueue_correction(n, role, reason, trace, %Seams{} = seams) do
    pod_id = Fleet.PodId.for_issue(seams.repo, n, role)

    attrs = %{
      issue_id: Fleet.Pilot.IssueId.compose(n),
      role: role,
      brief: correction_brief(reason),
      metadata: %{"issue" => n, "verdict_correction" => "round-1"}
    }

    case seams.task_queue.enqueue(pod_id, attrs) do
      {:ok, _} ->
        _ = safe_wake(seams.spawner, pod_id)

        Logger.info(
          "VerdictCorrection: #{seams.repo}##{n} — ONE envelope-correction pass requested from " <>
            "#{role} (pod #{pod_id} still alive, its reading of the deliverable is what we spend)"
        )

        {:ok, :correction_requested}

      {:error, why} ->
        # Le marqueur est POSÉ et le brief n'est pas parti : la passe est comptée sans avoir été
        # jouée. On gèle plutôt que de réessayer — réessayer lirait le marqueur et escaladerait,
        # avec un motif qui dirait « déjà dépensée » là où rien n'a été demandé.
        Logger.warning(
          "VerdictCorrection: #{seams.repo}##{n} marker posted but brief NOT enqueued " <>
            "(#{inspect(why)}) — freezing rather than reporting a pass that never ran"
        )

        freeze(n, role, trace, {:correction_undispatchable, why}, seams)
    end
  end

  defp correction_brief(reason) do
    """
    # Correction d'enveloppe — une passe

    Ton verdict précédent a été REFUSÉ SUR SA FORME, pas sur son contenu. Le rail ne l'a pas lu :
    il n'a pas pu le décoder.

    **Ce qui n'allait pas** : #{describe(reason)}

    ## Ce qui t'est demandé

    Renvoie le MÊME jugement, correctement emballé, via `mcp__fleet__submit_result`. L'enveloppe est
    `gate-decision.json` : `decision` et `reason` sont obligatoires ; `details` est un objet de
    scalaires PLUS la clé `findings` qui est un objet ; `chain` est un tableau de chaînes NUES.

    ⚠ **Ne refais pas ton analyse.** Tu as lu le livrable, ton opinion est la tienne et elle ne
    change pas parce qu'un champ était mal typé. Ce qui est demandé ici est un ré-emballage.

    ⚠ **Une seule passe.** Si cette sortie ne valide pas non plus, le ticket est remis à
    l'architecte — et ce sera la bonne décision : une enveloppe qui reste malformée après qu'on t'a
    dit exactement ce qui clochait n'est plus un problème de forme.
    """
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp freeze(n, role, trace, why, %Seams{} = seams) do
    # Le gel dit POURQUOI la passe n'a pas eu lieu, jamais seulement qu'elle n'a pas eu lieu : un
    # architecte doit pouvoir distinguer un barreau non armé d'un barreau dépensé.
    TerminalEscalation.freeze_to_arch(
      n,
      role,
      "halt_invalid",
      trace <> "\n\n(passe de correction d'enveloppe : #{inspect(why)})",
      seams.terminal
    )
  end

  defp safe_wake(spawner, pod_id) do
    if Fleet.Opts.exported?(spawner, :wake_pod, 1), do: spawner.wake_pod(pod_id), else: :ok
  rescue
    _ -> :ok
  end
end

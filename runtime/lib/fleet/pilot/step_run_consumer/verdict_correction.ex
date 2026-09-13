defmodule Fleet.Pilot.StepRunConsumer.VerdictCorrection do
  @moduledoc """
  Demande au juge de re-emballer une enveloppe refusee, sans refaire son analyse.
  Le motif de validation doit voyager dans le brief ; halt_invalid ne prouve ni que
  le juge a compris le livrable ni qu'il est encore vivant.

  Le drapeau pilot_verdict_correction_pass? est eteint par defaut. Le marqueur forge
  [verdict-correction:issue-N borne l'admission par ticket, tous roles confondus,
  et survit aux redemarrages. Il precede l'enqueue : une passe peut etre comptee
  sans avoir tourne. Lecture, post et enqueue ne sont pas atomiques ; la dedup du
  commentaire ne garantit pas l'unicite des demandes concurrentes.

  La correction cible un PodId.for_issue, sans verifier sa presence ni le recreer.
  Un verdict toujours malforme conduit a l'architecte par politique de budget,
  pas parce qu'une seconde erreur etablirait une incomprehension de fond.
  """

  require Logger

  alias Fleet.Pilot.StepRunConsumer.TerminalEscalation

  defmodule Seams do
    @moduledoc """
    Dependances de correction. enforce_keys impose leur presence, pas une valeur non-nil.
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
  Transmet reason au juge apres post du marqueur, ou delegue le gel a l'architecte.

  Apres enqueue reussi, rend correction_requested meme si le wake manque, rend une
  erreur ou leve une exception (rescue). Throws et exits peuvent encore propager.
  Aucun accuse de reception du juge ni continuation gate_eval n'est ajoute ici.
  """
  @spec request(pos_integer(), String.t(), term(), String.t(), Seams.t()) :: term()
  def request(n, role, reason, trace, %Seams{} = seams) do
    # Distinguer passe desarmee et passe epuisee dans le motif du gel.
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
  # Compte illisible et passe epuisee partagent le meme motif d'escalade.
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
        # Ne pas enfiler une passe que le compteur ne pourra pas voir.
        Logger.warning(
          "VerdictCorrection: #{seams.repo}##{n} marker NOT posted (#{inspect(why)}) — no " <>
            "correction requested (an unrecorded pass is an unbounded one)"
        )

        freeze(n, role, trace, {:correction_marker_unposted, why}, seams)
    end
  end

  # Identite de juge de gate par ticket ; ce calcul ne prouve pas sa vivacite.
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
        # Enqueue refuse apres marqueur : geler avec le motif d'admission ratee, pas de passe executee.
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
    # Conserver la cause de non-correction avec la trace du verdict pour l'architecte.
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

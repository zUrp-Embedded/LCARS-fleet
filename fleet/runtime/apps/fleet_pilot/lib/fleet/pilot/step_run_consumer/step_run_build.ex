defmodule Fleet.Pilot.StepRunConsumer.StepRunBuild do
  @moduledoc """
  Construction du **step_run PR-natif** depuis l'event `pod.completed`, extraite de
  `Fleet.Pilot.StepRunConsumer` : classe le rôle qui FINIT (producteur/juge), résout la
  branche PR, et assemble la map `step_run` que `StepRunCompleter.complete_pr` route.

  ## Pourquoi un module séparé

  Le consumer orchestre (Bus → décision → complétion) ; la CONSTRUCTION est de
  l'assemblage de données quasi-pur — une entrée (payload + routage décidé), une sortie
  (la map step_run). Un seul effet assumé : la résolution de la branche producteur d'un
  JUGE (`list_open_pulls`, la seule lecture forge nécessaire pour retrouver la PR à
  reviewer). L'appelant garde la discipline d'exécution (E4 : `build/5` est appelé DANS
  la closure offloadée — cette I/O ne bloque jamais la mailbox du singleton).

  ## Classification producteur/juge (engineer-first)

    * PRODUCTEUR = rôle `git_native` (engineer) → pousse le code, ouvre la PR
      (head = sa propre branche `feature_branch(n, role)`), porte `deliverable_opts`
      (le SYSTÈME vérifie + pousse) + sa voix `eng_summary`.
    * JUGE = rôle `payload` (qualifier/reviewer en AVAL) → review la PR du producteur
      (head résolu SANS workflow_map via `parse_feature_branch`), pas de livrable git ;
      en intent `:reviewed` porte `review_event` (verdict fail-closed) + `review_body`.
    * Un juge sans producteur résoluble → `producer_branch: nil` → `complete_pr`
      fail-loud `:no_producer_branch` (JAMAIS un mauvais merge).

  ## Frontière blindée

  `Seams` (struct étroit) porte les 6 seules lectures autorisées — pas le state du
  consumer. Le classement producteur/juge délègue à l'autorité unique
  `GateEngine.producer?/2` (même critère que la décision de gate).
  """

  alias Fleet.Pilot.StepRunConsumer.GateEngine
  alias Fleet.Pilot.StepRunConsumer.Verdict

  defmodule Seams do
    @moduledoc """
    Frontière blindée de la construction : les SEULES lectures que `StepRunBuild` peut
    faire. Construit par le consumer depuis son state DÉRIVÉ per-step-run
    (`repo`/`remote` viennent de l'event, multi-projet).
    """
    @enforce_keys [:repo, :remote, :role_emails, :deliverable_mode_fun, :forge_opts]
    defstruct [
      # Repo "owner/name" du step_run (per-step-run, dérivé de l'event).
      :repo,
      # URL/nom du remote où le système pousse le livrable (per-step-run).
      :remote,
      # fn role -> [email] — la gate d'identité vérifie l'email du committer.
      :role_emails,
      # Résout le deliverable_mode d'un rôle ("git_native" producteur / "payload" juge).
      :deliverable_mode_fun,
      # Client forge injectable (nil → Fleet.Pilot.ForgeClient) — résolution branche juge.
      :forge_client,
      # Opts forge (token…) pour la résolution de branche juge.
      :forge_opts
    ]

    @type t :: %__MODULE__{
            repo: String.t() | nil,
            remote: String.t() | nil,
            role_emails: (String.t() -> [String.t()]),
            deliverable_mode_fun: (String.t() -> String.t()),
            forge_client: module() | nil,
            forge_opts: keyword()
          }
  end

  @typedoc """
  Routage décidé en amont (GateEngine / apply_verdict) : `intent` obligatoire ;
  `comment_body` (trace verdict gatekeeper) et `judge_target` (brief-review) optionnels.
  """
  @type route :: %{
          required(:intent) => atom(),
          required(:next_assignee) => String.t() | nil,
          required(:next_step) => String.t() | nil,
          optional(:comment_body) => String.t() | nil,
          optional(:judge_target) => String.t() | nil
        }

  @doc """
  Bâtit la map `step_run` complète (classement pr_role + deliverable/review/eng_summary)
  pour `StepRunCompleter.complete_pr/2`. `next_step` est un pont transitionnel :
  workflow_map+next_step gravent la route que le StepDispatcher lit pour spawner le step
  suivant. `comment_body` (trace verdict gatekeeper sur continue) est porté mais pas
  encore matérialisé sur la PR — gap transitionnel noté (la trace vit dans le résultat
  de tâche du gatekeeper ; PR-trace = incrément ultérieur).
  """
  @spec build(map(), pos_integer(), String.t(), route(), Seams.t()) :: map()
  def build(payload, n, role, route, %Seams{} = seams) do
    {pr_role, producer_branch} = classify_pr_role(payload, n, role, seams)

    %{
      repo: seams.repo,
      # pod_id du PRODUCTEUR (depuis le payload pod.completed) : porte jusqu'a l'emission de
      # `deliverable.published` (slot-freeze) pour adresser le pod resident a remettre :ready.
      pod_id: payload["pod_id"],
      issue_number: n,
      role: role,
      pr_role: pr_role,
      intent: route.intent,
      next_assignee: route.next_assignee,
      # Pont transitionnel : workflow_map_name+next_step gravent la route que le StepDispatcher lit
      # pour spawner le step suivant (retire a l'increment 4, switch sur la review-request).
      next_step: route.next_step,
      workflow_map: payload["workflow_map"],
      producer_branch: producer_branch,
      base_branch: "main"
    }
    |> put_unless_nil(:comment_body, Map.get(route, :comment_body))
    # judge_target (brief|nil) → complete_judge décide trace review-PR vs commentaire-issue ;
    # absent (chemin normal/gatekeeper) → comportement PR par défaut (fail-loud si pas de PR).
    |> put_unless_nil(:judge_target, Map.get(route, :judge_target))
    |> maybe_put_deliverable(pr_role, role, payload, n, seams)
    |> maybe_put_review_event(pr_role, route.intent, payload)
    |> maybe_put_eng_summary(pr_role, payload)
  end

  # Classe le role qui finit (engineer-first). Producteur = role git_native (engineer) →
  # pousse le code, ouvre la PR (head = sa propre branche). Juge = role payload (qualifier/reviewer
  # en AVAL) → review la PR du producteur (head = le head.ref de la PR ouverte de l'issue, résolu
  # sans workflow_map via `parse_feature_branch`). Un juge sans producteur resoluble → `producer_branch`
  # nil → `complete_pr` fail-loud `:no_producer_branch` (jamais un mauvais merge). Les steps design
  # AMONT du producteur (architect) sont hors-scope (decision engineer-first, mapping PR).
  defp classify_pr_role(payload, n, role, seams) do
    if GateEngine.producer?(role, seams.deliverable_mode_fun) do
      # Format feature-branch = source unique `Fleet.Pilot.ForgeProtocol.feature_branch/2` (collé à son
      # parseur `parse_feature_branch/1`) — pas de construction `lcars/issue-...` en dur ici.
      {:producer, Fleet.Pilot.ForgeProtocol.feature_branch(n, role)}
    else
      {:judge, judge_producer_branch(payload, n, seams)}
    end
  end

  # Sans workflow_map : le producteur = celui qui a OUVERT la PR de l'issue N.
  # Sa branche = le `head.ref` de cette PR (`lcars/issue-N-<producteur>`), retrouvée en listant les PR
  # ouvertes + `parse_feature_branch` (même pattern que le Poller). Le modèle 1-brique=1-producteur
  # n'a pas de workflow_map (sans `payload["workflow_map"]`, une résolution workflow_map rendrait nil → merge
  # cassé). Aucune PR résoluble → nil → `complete_pr` fail-loud `:no_producer_branch` (jamais un
  # mauvais merge).
  defp judge_producer_branch(_payload, n, seams) do
    forge = seams.forge_client || Fleet.Pilot.ForgeClient

    with {:ok, pulls} <- forge.list_open_pulls(seams.repo, seams.forge_opts),
         head when is_binary(head) <- producer_head_for_issue(pulls, n) do
      head
    else
      _ -> nil
    end
  end

  # La branche producteur de l'issue N = le `head.ref` de la (1ʳᵉ) PR ouverte dont le head parse
  # vers l'issue N. Ambiguïté (≥2 PR pour N — anormal) → la première ; aucune → nil (fail-loud aval).
  defp producer_head_for_issue(pulls, n) do
    Enum.find_value(pulls, fn pr ->
      head = get_in(pr, ["head", "ref"]) || ""

      case Fleet.Pilot.ForgeProtocol.parse_feature_branch(head) do
        {:ok, {^n, _role}} -> head
        _ -> false
      end
    end)
  end

  # Le producteur (engineer) porte sa `deliverable_opts` (publish vers sa feature-branch) ; le juge
  # review (il ne pousse pas — son verdict est une review native), pas de livrable git.
  defp maybe_put_deliverable(step_run, :producer, role, payload, n, seams),
    do: Map.put(step_run, :deliverable_opts, build_deliverable_opts(role, payload, n, seams))

  defp maybe_put_deliverable(step_run, :judge, _role, _payload, _n, _seams), do: step_run

  # Livrable d'un step_run métier : `:git_native`. Le pod a commité dans son workspace,
  # le système vérifie (gate identité/ancêtre) + pousse. Il n'existe PAS
  # de step `role: gatekeeper` → pas de branche `:payload`/verdict.json ici (le verdict
  # du gatekeeper est tracé par `resume_gate`, pas matérialisé comme livrable de step).
  defp build_deliverable_opts(role, payload, n, seams) do
    %{
      mode: :git_native,
      workspace: payload["workspace"],
      # La gate d'ancêtre se base sur `gate_base_sha` (DÉCONFLÉ de la clone-base) :
      # pour une résolution par rebase, HEAD descend de `main` (cible du rebase), pas de l'ancien tip de
      # feature (réécrit → `base_not_ancestor`). Forward (build/rework) : le resolver pose
      # `gate_base_sha == base_sha`. Fallback `base_sha` (payload nu de test / spawn antérieur au champ).
      base_sha: payload["gate_base_sha"] || payload["base_sha"],
      allowed_emails: seams.role_emails.(role),
      # La gate d'identité vérifie le trailer `Co-authored-by: LCARS-<role>` (signature rôle).
      coauthor_role: role,
      remote: seams.remote,
      # Format feature-branch = source unique `Fleet.Pilot.ForgeProtocol.feature_branch/2` (collé au parseur).
      target_branch: Fleet.Pilot.ForgeProtocol.feature_branch(n, role),
      push?: true,
      local_ref: "HEAD"
    }
  end

  # Pour un JUGE no-workflow_map (intent `:reviewed`), le verdict de review (APPROVE/REQUEST_CHANGES)
  # est lu du gate-decision rendu par le pod (GateBrief : `continue`/`abandon`). On le mappe ici et on
  # le porte dans le step_run (`:review_event`) → `StepRunCompleter.record_review` poste la review correspondante.
  # `continue`→approve ; tout le reste (`abandon`/redirect/escalate/halt/illisible)→**request_changes**
  # (fail-closed DÉCISIF). PAS `:comment` : une review COMMENT n'est pas décisive → le juge resterait
  # « non tranché » et serait re-jugé en boucle. Un verdict non-`continue` = pas vert
  # → on bloque le merge (rework), jamais un merge sur verdict douteux. (escalade-gatekeeper d'un verdict
  # non-trivial = backlog ; ici fail-closed strict.)
  defp maybe_put_review_event(step_run, :judge, :reviewed, payload) do
    result = Verdict.unwrap_worker_envelope(payload["result"] || %{})
    event = Verdict.review_event(Verdict.gate_decision(result))
    step_run = Map.put(step_run, :review_event, event)

    # Le juge PRODUIT un `reason`/`details`/`chain` dans sa gate-decision → on le REND sur la review
    # (visu humaine + rework actionnable). Sinon `StepRunCompleter.record_review` retombe sur le corps
    # générique (« la brique ne satisfait pas son critère »), inactionnable — pour l'humain comme pour
    # le producteur en rework. On ne pose `:review_body` QUE s'il y a de la substance (sans
    # quoi `Map.get(step_run, :review_body, default)` renverrait `nil` au lieu du défaut).
    case Verdict.judge_review_body(event, result) do
      body when is_binary(body) and body != "" -> Map.put(step_run, :review_body, body)
      _ -> step_run
    end
  end

  defp maybe_put_review_event(step_run, _pr_role, _intent, _payload), do: step_run

  # VOIX DE L'ENG (info SORTANTE) : le PRODUCTEUR peut rendre un `summary` markdown dans submit_result
  # (ce qu'il a fait / réponse à la review / motif blocked). On l'extrait du résultat (déplié de
  # l'enveloppe worker) → `StepRunCompleter` le poste en commentaire PR (`as_role` engineer). Coercé par
  # `safe_str` (l'eng peut rendre un non-binaire → ne pas crasher le singleton). Absent/vide → rien
  # posé. Jumeau SORTANT de la famine d'info ENTRANTE — complète la « panne bidirectionnelle de substance ».
  defp maybe_put_eng_summary(step_run, :producer, payload) do
    case Verdict.eng_summary(payload) do
      "" -> step_run
      summary -> Map.put(step_run, :eng_summary, summary)
    end
  end

  defp maybe_put_eng_summary(step_run, _pr_role, _payload), do: step_run

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end

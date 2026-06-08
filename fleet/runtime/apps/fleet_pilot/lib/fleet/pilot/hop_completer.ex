defmodule Fleet.Pilot.HopCompleter do
  @moduledoc """
  Primitive de **fin-de-hop** (DN `orchestration/forge-state-machine.md` §5).
  Quand un pod (stage courant) a terminé, le **SYSTÈME** — pas le pod, qui n'a
  ni token ni outil forge (barrière §4) — applique la transition vers le stage
  suivant. C'est la pièce qui REMPLACE le chaînage inter-stage de l'Executor
  (RAM) par une séquence forge-driven idempotente.

  ## Séquence ordonnée idempotente (§5)

  L'atomicité est impossible (Gitea n'a pas de transaction ; un hop = ~5
  écritures HTTP). On la remplace par un ORDRE où le trigger du poller (PATCH
  assignee) est l'**avant-dernier** et le verrou est levé en **dernier** :

    1. **Commit + push livrable** — délégué à `Deliverable.publish` (O5 : gate
       I-CBC F-03/F-01/F-02 + push borné). Indissociables : le commit local seul
       n'est pas vu par la forge. Retourne le `commit_sha` qui signe le hop.
    2. **Comment signé** `[hop:<role>:<sha>]` — dédup par signature (replay-safe).
    3. **PATCH `state:*`** — `set_state_label` (DELETE ancien + PUT nouveau).
    4. **Routage du stage suivant** :
         * `next_assignee` présent (multi-stage) → `set_assignee(next)` ; le
           poller ne verra le suivant que quand 1-3 sont OK. **(branche A2 — le
           calcul de `next_assignee` depuis la carte est hors A1.)**
         * `next_assignee == nil` (1-stage / terminal) → `close_issue`.
    5. **Retire `lcars-in-flight`** — en DERNIER : le poller ne re-spawn le
       suivant que quand TOUT est fini.

  **Garantie crash** : un crash à n'importe quelle étape laisse le verrou posé
  (sauf après 5) → le poller ne re-spawn pas ; la recovery (§7) rejoue la
  séquence, les étapes faites skippent (write-ops idempotentes + dédup comment +
  push idempotent). Pas de double-livrable ni double-comment.

  ## Seams

  `:deliverable` (défaut `Fleet.Pipeline.Deliverable`), `:forge_client` (défaut
  `Fleet.Pilot.ForgeClient`) — stubés en test. `:deliverable_opts` quand le hop
  produit un livrable git ; absent/`nil` = pas de livrable git (ex. verdict de
  juge en mode payload — le `hop_sha` est alors fourni explicitement).
  """

  require Logger

  @in_flight_label "lcars-in-flight"

  @typedoc """
  Décrit la fin-de-hop d'un rôle sur une issue.

    * `:repo` / `:issue_number` — cible forge (obligatoires)
    * `:role` — le rôle qui vient de finir (signe le comment)
    * `:deliverable_opts` — opts passés tel quel à `Deliverable.publish/1`
      (mode/workspace/base_sha/remote/target_branch/...). `nil` = pas de
      livrable git ; alors `:hop_sha` requis.
    * `:hop_sha` — override de la signature de hop (défaut = commit_sha publié)
    * `:next_assignee` — login du rôle suivant (carte) ; `nil` = terminal → close
    * `:state_label` — label `state:*` à poser (défaut `"state:delivered"`)
    * `:comment_body` — corps lisible du comment (la signature machine est
      toujours ajoutée) ; défaut généré
  """
  @type hop :: %{
          required(:repo) => String.t(),
          required(:issue_number) => integer(),
          required(:role) => String.t(),
          optional(:deliverable_opts) => map() | nil,
          optional(:hop_sha) => String.t(),
          optional(:next_assignee) => String.t() | nil,
          optional(:state_label) => String.t(),
          optional(:comment_body) => String.t()
        }

  @doc """
  Applique la séquence de fin-de-hop §5. Idempotente sur replay.

  `opts` : seams `:deliverable` / `:forge_client` / `:forge_opts`.

  Retourne `{:ok, :completed}` (terminal → issue fermée) | `{:ok, :reassigned}`
  (multi-stage → assignee suivant posé) | `{:error, {step, reason}}`.
  """
  @spec complete(hop(), keyword()) ::
          {:ok, :completed | :reassigned} | {:error, {atom(), term()}}
  def complete(hop, opts \\ []) when is_map(hop) do
    deliverable = Keyword.get(opts, :deliverable, Fleet.Pipeline.Deliverable)
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    repo = Map.fetch!(hop, :repo)
    n = Map.fetch!(hop, :issue_number)
    role = Map.fetch!(hop, :role)
    state_label = Map.get(hop, :state_label, "state:delivered")

    with {:ok, sha} <- step1_publish(hop, deliverable),
         {:ok, _} <- step2_comment(forge, repo, n, role, sha, hop, forge_opts),
         {:ok, _} <- step3_state(forge, repo, n, state_label, forge_opts),
         {:ok, routed} <- step4_route(forge, repo, n, hop, forge_opts),
         {:ok, _} <- step5_unlock(forge, repo, n, forge_opts) do
      Logger.info(
        "HopCompleter: #{repo}##{n} role=#{role} sha=#{sha} → #{routed} (state=#{state_label})"
      )

      {:ok, routed}
    end
  end

  @awaits_human_label "lcars-awaits-human"

  @doc """
  Fin-de-hop ALTERNATIVE (A2.3b, DN `gatekeeper-forge-encoding-v2` §3/§6) : un verdict
  gatekeeper **humain** (`escalate_user`/`halt_wait_input`/`redirect`/absent/invalide).
  Le SYSTÈME pose `lcars-awaits-human` + retire le verrou ; NE close PAS, NE reassign PAS.
  L'issue attend une action humaine **via l'arch** (`convention-tickets-gitea-v2` §7/§8) ;
  le poller la **SKIP** (`StageDispatcher.decide` → `:awaits_human`).

  Pas de livrable git ici (le verdict vit dans le comment signé ; `verdict.json` =
  item `submit_result` séparé). Ordre : comment → `lcars-awaits-human` → unlock (DERNIER,
  même principe §5 : un crash laisse le verrou → poller skip → recovery rejoue,
  idempotent via dédup comment + add/remove label idempotents).

  `hop` : `:repo`, `:issue_number`, `:role`, `:decision`. Returns `{:ok, :awaiting_human}`
  | `{:error, {:await_human, reason}}`.
  """
  @spec await_human(map(), keyword()) :: {:ok, :awaiting_human} | {:error, {:await_human, term()}}
  def await_human(hop, opts \\ []) when is_map(hop) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(hop, :repo)
    n = Map.fetch!(hop, :issue_number)
    role = Map.fetch!(hop, :role)
    decision = Map.get(hop, :decision)

    signature = "[hop:#{role}:await:#{decision}]"

    body =
      "Verdict du juge **#{role}** : `#{inspect(decision)}` → escalade humaine. " <>
        "L'issue attend une action via l'arch (`lcars-awaits-human`).\n\n" <> signature

    with {:ok, _} <-
           forge.post_comment(repo, n, body, Keyword.put(forge_opts, :dedup_signature, signature)),
         {:ok, _} <- forge.add_label(repo, n, @awaits_human_label, forge_opts),
         {:ok, _} <- forge.remove_label(repo, n, @in_flight_label, forge_opts) do
      Logger.info(
        "HopCompleter: #{repo}##{n} role=#{role} → awaiting_human (decision=#{inspect(decision)})"
      )

      {:ok, :awaiting_human}
    else
      {:error, reason} -> {:error, {:await_human, reason}}
    end
  end

  # ── Étape 1 : commit + push livrable (ou hop_sha fourni si pas de git) ──────
  defp step1_publish(hop, deliverable) do
    case Map.get(hop, :deliverable_opts) do
      nil ->
        case Map.get(hop, :hop_sha) do
          sha when is_binary(sha) and sha != "" -> {:ok, sha}
          _ -> {:error, {:publish, :no_deliverable_no_hop_sha}}
        end

      d_opts when is_map(d_opts) ->
        case deliverable.publish(d_opts) do
          {:ok, %{commit_sha: sha}} -> {:ok, Map.get(hop, :hop_sha, sha)}
          {:error, reason} -> {:error, {:publish, reason}}
        end
    end
  end

  # ── Étape 2 : comment signé [hop:role:sha], dédup ──────────────────────────
  defp step2_comment(forge, repo, n, role, sha, hop, forge_opts) do
    signature = "[hop:#{role}:#{sha}]"

    body =
      Map.get(hop, :comment_body, default_comment(role, sha)) <>
        outputs_block(Map.get(hop, :outputs)) <> "\n\n" <> signature

    case forge.post_comment(repo, n, body, Keyword.put(forge_opts, :dedup_signature, signature)) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:comment, reason}}
    end
  end

  # A2.3b N-04 : quand le hop avance vers un gatekeeper-stage, le comment embarque le
  # `result_K` (les outputs du stage qui finit) → le juge (et la recovery) le lit sans
  # query séparée. JSON fencé si ≤ 8KB ; sinon note pointant vers le livrable de la
  # branche (jamais de JSON tronqué = invalide). `nil`/vide → rien (pas de bruit sur
  # les hops ordinaires).
  defp outputs_block(outputs) when is_map(outputs) and map_size(outputs) > 0 do
    json = Jason.encode!(outputs)

    if byte_size(json) <= 8192 do
      "\n\n```result\n#{json}\n```"
    else
      "\n\n_(result #{byte_size(json)} o — trop volumineux pour le comment ; livrable complet sur la branche système)_"
    end
  end

  defp outputs_block(_), do: ""

  # ── Étape 3 : PATCH state:* ────────────────────────────────────────────────
  defp step3_state(forge, repo, n, state_label, forge_opts) do
    case forge.set_state_label(repo, n, state_label, forge_opts) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:state, reason}}
    end
  end

  # ── Étape 4 : assignee suivant (A2) OU close (1-stage terminal) ────────────
  # Reassign : grave la ROUTE du stage suivant AVANT le PATCH assignee (A2.1) — le poller
  # ne doit voir le nouvel assignee qu'avec sa position carte déjà posée (sinon le spawn
  # suivant ne saurait pas quel stage il est). post_route idempotent (dédup marqueur).
  defp step4_route(forge, repo, n, hop, forge_opts) do
    case Map.get(hop, :next_assignee) do
      nil ->
        case forge.close_issue(repo, n, forge_opts) do
          {:ok, _} -> {:ok, :completed}
          {:error, reason} -> {:error, {:close, reason}}
        end

      next when is_binary(next) ->
        with {:ok, _} <- maybe_post_route(forge, repo, n, hop, forge_opts),
             {:ok, _} <- forge.set_assignee(repo, n, next, forge_opts) do
          {:ok, :reassigned}
        else
          {:error, reason} -> {:error, {:reassign, reason}}
        end
    end
  end

  defp maybe_post_route(forge, repo, n, hop, forge_opts) do
    case {Map.get(hop, :pipeline), Map.get(hop, :next_stage)} do
      {p, s} when is_binary(p) and is_binary(s) -> forge.post_route(repo, n, p, s, forge_opts)
      _ -> {:ok, :no_route}
    end
  end

  # ── Étape 5 : retire le verrou (DERNIER) ───────────────────────────────────
  defp step5_unlock(forge, repo, n, forge_opts) do
    case forge.remove_label(repo, n, @in_flight_label, forge_opts) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:unlock, reason}}
    end
  end

  defp default_comment(role, sha) do
    "Livrable de **#{role}** poussé par le système (fin-de-hop). Source: `#{sha}`."
  end
end

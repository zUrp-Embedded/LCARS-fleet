defmodule Fleet.Spawner.Pod.Kick do
  @moduledoc """
  DÉCISION + I/O de la boucle de réveil ack-driven (« kick ») — cluster extrait de `Fleet.Spawner.Pod`.

  La boucle de kick réveille le REPL claude d'un pod fraîchement lancé (mot-clé `yop` bootstrap) ou
  re-déclenche un pull de brief resté en attente (mot-clé `wake` fallback), jusqu'à ce que l'agent
  ACKE (il a tendu la main via get_work_item). Ce module porte les TROIS pièces sans état du tick :

  - **les bornes/cadences** (`kick_first_delay_ms`, `kick_retry_ms`, `kick_max_attempts`,
    `kick_bootstrap_max`, `kick_bootstrap_retry_ms`) : config `:fleet_spawner` lue à chaque tick ;
  - **les décisions PURES** (`acked?/3`, `kick_keyword/2`) : faut-il stopper la boucle (ACK) et,
    sinon, quel mot-clé envoyer (`yop`/`wake`/rien) — testables hors process ;
  - **l'I/O d'envoi** (`kick_send/2` → `do_send_keys/2`) : pousse le mot-clé dans le tmux du pod.

  Ce que le module ne porte PAS (RESTE au cœur du `Pod`, mécanique de timer/handler) : l'ARMEMENT du
  timer (`arm_kick`/`schedule_kick`/`cancel_kick` via `arm_managed_timer`), le HANDLER
  `handle_info({:kick_attempt, n}, ...)` (qui orchestre cap/retry/ACK et appelle ce module), et les
  SONDES TaskQueue (`polled?`/`brief_pulled?`/`no_pending_brief?`) que le handler passe déjà
  réduites en booléens à `acked?/3`.

  Aucun state propre, aucun timer armé ici : le `Pod` passe son `state` (map) en argument (`kick_send`
  lit `state.pod_id`) ; la config `:fleet_spawner` (bornes + knob `:wake_send_keys`) est lue
  directement. Dépend de `Fleet.Spawner.PodTmux` (l'envoi de send-keys), déjà une dep de l'app ; aucune
  dépendance vers `Fleet.Spawner.Pod` (pas de cycle).

  ## Contrat (appelé par `Pod`)

  - `kick_first_delay_ms/0` — délai du 1er tick (appelé par `arm_kick`, qui RESTE dans `Pod` car il ARME
    le timer).
  - `kick_retry_ms/0` / `kick_max_attempts/0` / `kick_bootstrap_retry_ms/0` / `kick_bootstrap_max/0` —
    cadence + cap, branche wake vs bootstrap (appelés par le handler `handle_info({:kick_attempt, n}, ...)`).
  - `acked?/3` (décision PURE) — l'agent a-t-il tendu la main ? STOP de la boucle (appelé par le handler ;
    le test l'exerce DIRECTEMENT via `Fleet.Spawner.Pod.Kick.acked?/3`, plus de wrapper délégant côté `Pod`).
  - `kick_keyword/2` (décision PURE) — mot-clé selon l'ACK (`yop`/`wake`/`nil`) (appelé par `kick_send` ;
    le test l'exerce DIRECTEMENT via `Fleet.Spawner.Pod.Kick.kick_keyword/2`, plus de wrapper délégant).
  - `kick_send/2` — choisit le mot-clé puis l'envoie au tmux du pod (appelé par le handler).

  `do_send_keys/2` est interne (appelé UNIQUEMENT par `kick_send`).
  """

  require Logger

  alias Fleet.Spawner.PodTmux

  # Kick AUTONOME « yop » readiness-gated. Déclenche le pull du brief
  # par MCP get_work_item — le brief n'est PAS injecté (il vit dans issues/ + TaskQueue).
  # No-op si pas de tmux_session (StubBackend ; LauncherPortBackend en pose un, bwrap ou host).
  #
  # Pourquoi pas un délai FIXE : le claude REPL n'est pas prêt à un instant connu — il
  # boote (tmux server up, banner, init MCP servers via .mcp-fleet.json), durée variable.
  # Un yop à délai fixe arrive trop tôt et est perdu (le sock du serveur tmux n'existe pas
  # encore). On planifie donc une BOUCLE bornée : à chaque tick, si le serveur tmux est
  # joignable (`PodTmux.alive?`) on envoie yop ; on s'arrête dès que le brief est pull
  # (task ≠ pending) ou au cap. Non-bloquant (send_after + handle_info), le pod passe à
  # :monitor entretemps. Intervalles configurables (test : valeurs ~ms).
  def kick_first_delay_ms, do: Application.get_env(:fleet_spawner, :kick_first_delay_ms, 2_000)
  def kick_retry_ms, do: Application.get_env(:fleet_spawner, :kick_retry_ms, 2_500)
  def kick_max_attempts, do: Application.get_env(:fleet_spawner, :kick_max_attempts, 12)

  # Bootstrap (pod sans brief) : kicks BORNÉS + ESPACÉS jusqu'à ce que le REPL claude réponde (appel
  # get_work_item = ack). La fenêtre doit couvrir le COLD-START réel de claude en bwrap (binaire ~238 MB,
  # caches froids, contention multi-fleet) : un défaut trop court (≈32s, calé sur un boot ~15s)
  # verrait tous les kicks tomber avant REPL prêt → pod jamais onboardé. D'où 30×8s ≈ 4 min : couvre
  # le cold-start, et le deadline résultat se RÉ-ARME sur activité (donc dès le brief reçu, plus de
  # timeout). Une fois acké, le réveil-par-flag prend le relais.
  def kick_bootstrap_max, do: Application.get_env(:fleet_spawner, :kick_bootstrap_max, 30)

  def kick_bootstrap_retry_ms,
    do: Application.get_env(:fleet_spawner, :kick_bootstrap_retry_ms, 8_000)

  @doc false
  # ACK (décision PURE, testable) = l'agent a tendu la main. C'est LE contrôle de la boucle :
  # pas d'ACK → on (re)trigger ; ACK → stop ; cap sans ACK → escalade. Wake → `pulled?` (brief_pulled? :
  # le pull PROUVE get_work_item) ; bootstrap (permanent sans brief) → `polled` (last_poll = up + SP lu).
  def acked?(pulled?, bootstrap?, polled), do: pulled? or (bootstrap? and polled)

  # Mot-clé du kick selon `polled` (= l'agent a déjà appelé get_work_item) :
  #   - pas encore pollé → `"yop"` : bootstrap-arm, IRRÉDUCTIBLE (seul moyen de démarrer/armer l'agent) ;
  #   - déjà pollé (pod running) → `"wake"` : FALLBACK (le porteur/flag aurait dû livrer), GATÉ par
  #     `:wake_send_keys` (off ⇒ flag-only : on valide le Monitor en isolation, pas de fallback).
  # Le `"yop"` bootstrap n'est JAMAIS gaté (sinon un pod neuf ne démarrerait pas). Mots-clés discriminés
  # ⇒ on sait, en lisant le REPL/les logs, si c'est un kick (démarrage) ou un fallback (Monitor raté).
  def kick_send(state, polled) do
    case kick_keyword(polled, Application.get_env(:fleet_spawner, :wake_send_keys, true)) do
      nil -> :ok
      key -> do_send_keys(state, key)
    end
  end

  @doc false
  # Décision PURE du mot-clé (testable). `polled` = l'agent a déjà appelé get_work_item ; `fallback_on?` = knob
  # `:wake_send_keys`. `nil` ⇒ pas de send-keys (flag-only). Le `"yop"` (bootstrap) n'est JAMAIS gaté.
  def kick_keyword(polled, fallback_on?) do
    cond do
      not polled -> "yop"
      fallback_on? -> "wake"
      true -> nil
    end
  end

  defp do_send_keys(state, key) do
    case PodTmux.send_keys(state.pod_id, key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("pod #{state.pod_id} kick (#{key}) failed : #{inspect(reason)}")
    end
  end
end

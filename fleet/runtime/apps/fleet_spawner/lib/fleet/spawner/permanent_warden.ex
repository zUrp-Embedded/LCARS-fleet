defmodule Fleet.Spawner.PermanentWarden do
  @moduledoc """
  Respawn des pods PERMANENTS morts (G5, cattle rebuildable) — consumer Bus de `pod.failed`.

  Un pod permanent (`permanent-<role>` : architect, gatekeeper, …) est `restart: :temporary` cote OTP
  (comme tout pod : le respawn est EVENT-driven, pas supervisor-driven — un restart OTP brut relancerait
  le gen_statem sans la sequence de boot propre). Avant ce module, sa mort etait un stop DEFINITIF
  jusqu'au restart BEAM : le seul filet etait le reboot implicite du gatekeeper au prochain kick
  d'escalade — un archivist/architect mort restait absent en silence.

  ## Mecanique

  `pod.failed` d'un pod `permanent-*` → respawn PLANIFIE avec backoff exponentiel plafonne, via
  `PermanentBoot.respawn/2` (le MEME chemin que le boot : pod_id deterministe idempotent + boot-from-base
  = contexte FRAIS depuis la base versionnee — jamais la session accumulee du mort).

  ## Depense BORNEE (le mode de panne = depense, jamais un churn)

  Chaque respawn reussi boote une session claude : un crash-loop non borne brulerait du LLM en boucle.
  Le retry est donc BORNE : `@max_attempts` tentatives consecutives par role (backoff 5s → 40s → 3m →
  10m → 10m), compteur remis a zero sur respawn REUSSI. Epuise → HALT du retry + `Logger.error`
  (le role reste mort jusqu'a intervention). Ce halt n'est PAS silencieux : l'escalade humaine est
  DEJA passee par le rail incident (`IncidentConsumer` grave chaque `pod.failed` ; la RECURRENCE de la
  meme signature ouvre une issue sysadmin `error_system` sur la forge — rail repare F-RUN-2) — le
  warden n'a donc AUCUN cablage d'escalade a porter (composition, pas de fork d'autorite).

  ## Seams (tests)

    * `:subscribe` (defaut true) — abonnement Bus reel.
    * `:respawn_fun` (defaut `&Fleet.Spawner.PermanentBoot.respawn/1`) — `(role) -> {:ok, pod_id} | {:error, _}`.
    * `:backoff_base_ms` (defaut 5_000) — base du backoff (reduite en test).
  Gate de boot : `:fleet_spawner, :start_permanent_warden` (defaut true prod, false test — hermeticite).
  """

  use GenServer

  require Logger

  alias Fleet.EventRouter.Bus

  # Bornes de la depense : 5 tentatives consecutives max par role, backoff expo plafonne a 10 min.
  @max_attempts 5
  @max_delay_ms 600_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: :ok = Bus.subscribe()
    respawn_fun = Keyword.get(opts, :respawn_fun, &Fleet.Spawner.PermanentBoot.respawn/1)
    base = Keyword.get(opts, :backoff_base_ms, 5_000)
    {:ok, %{respawn_fun: respawn_fun, base: base, attempts: %{}}}
  end

  @impl true
  # Mort d'un pod PERMANENT → planifie le respawn (backoff selon le compteur du role). Les pods
  # non-permanents (issue-*, pr-*) ne matchent pas le prefixe → catch-all no-op (leur relance est
  # le job du rail forge : reconciliation + re-dispatch).
  def handle_info(
        %Fleet.Event{
          source: :spawner,
          type: :"pod.failed",
          payload: %{"pod_id" => "permanent-" <> role}
        },
        state
      )
      when is_binary(role) and role != "" do
    attempt = Map.get(state.attempts, role, 0)

    if attempt < @max_attempts do
      delay = backoff_delay(attempt, state.base)

      Logger.warning(
        "PermanentWarden: permanent #{role} mort → respawn dans #{div(delay, 1000)}s " <>
          "(tentative #{attempt + 1}/#{@max_attempts})"
      )

      Process.send_after(self(), {:respawn, role}, delay)
      {:noreply, %{state | attempts: Map.put(state.attempts, role, attempt + 1)}}
    else
      # Borne de depense atteinte : HALT du retry. Pas silencieux — la recurrence de pod.failed a DEJA
      # ouvert une issue sysadmin via le rail incident ; on ne brule pas de LLM en boucle infinie.
      Logger.error(
        "PermanentWarden: permanent #{role} — #{@max_attempts} respawns consecutifs epuises, HALT " <>
          "(issue sysadmin deja ouverte par le rail incident ; intervention requise)"
      )

      {:noreply, state}
    end
  end

  def handle_info({:respawn, role}, state) do
    case state.respawn_fun.(role) do
      {:ok, pod_id} ->
        Logger.info("PermanentWarden: permanent #{role} respawne (#{pod_id})")
        # Respawn REUSSI → compteur remis a zero (une mort ULTERIEURE repart en backoff court).
        {:noreply, %{state | attempts: Map.delete(state.attempts, role)}}

      {:error, reason} ->
        # Echec du spawn LUI-MEME (pas une mort de pod) : pas de pod.failed emis pour re-armer le
        # cycle → on re-planifie ICI, meme compteur/backoff que via l'event (une seule mecanique).
        attempt = Map.get(state.attempts, role, 1)

        if attempt < @max_attempts do
          delay = backoff_delay(attempt, state.base)

          Logger.warning(
            "PermanentWarden: respawn #{role} ECHOUE (#{inspect(reason)}) → retry dans " <>
              "#{div(delay, 1000)}s (tentative #{attempt + 1}/#{@max_attempts})"
          )

          Process.send_after(self(), {:respawn, role}, delay)
          {:noreply, %{state | attempts: Map.put(state.attempts, role, attempt + 1)}}
        else
          Logger.error(
            "PermanentWarden: respawn #{role} — #{@max_attempts} echecs consecutifs, HALT " <>
              "(issue sysadmin deja ouverte par le rail incident ; intervention requise)"
          )

          {:noreply, state}
        end
    end
  end

  # Tout autre event / message → no-op (consumer filtrant, comme PublishConsumer).
  def handle_info(_other, state), do: {:noreply, state}

  @doc "Backoff exponentiel plafonne : base * 2^attempt, cap #{@max_delay_ms} ms. Pur (testable)."
  @spec backoff_delay(non_neg_integer(), pos_integer()) :: pos_integer()
  def backoff_delay(attempt, base_ms)
      when is_integer(attempt) and attempt >= 0 and is_integer(base_ms) and base_ms > 0 do
    # E5 : guards TYPÉS (`> 0` seul laissait passer un float → tout le calcul devenait float,
    # la spec mentait) + shift `1 <<< n` (le type d'Integer.pow inclut un chemin float).
    import Bitwise, only: [<<<: 2]
    min(base_ms * (1 <<< min(attempt, 20)), @max_delay_ms)
  end
end

defmodule Fleet.Spawner.PermanentWardenTest do
  @moduledoc """
  G5 — respawn des permanents morts. Seams : `subscribe: false` (pas de Bus réel — on envoie les
  events directement au process), `respawn_fun` stub, `backoff_base_ms: 1` (delais ~ms, test rapide).
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.PermanentWarden

  defp start_warden(respawn_fun) do
    start_supervised!(
      {PermanentWarden, name: nil, subscribe: false, respawn_fun: respawn_fun, backoff_base_ms: 1}
    )
  end

  defp pod_failed(pod_id) do
    %Fleet.Event{
      source: :spawner,
      type: :"pod.failed",
      timestamp: DateTime.utc_now(),
      payload: %{"pod_id" => pod_id, "reason" => "test"}
    }
  end

  test "pod.failed d'un permanent → respawn (via backoff) ; compteur remis à zéro sur succès" do
    parent = self()

    warden =
      start_warden(fn role ->
        send(parent, {:respawn, role})
        {:ok, "permanent-#{role}"}
      end)

    send(warden, pod_failed("permanent-architect"))
    # backoff_base 1ms → le respawn planifié arrive vite.
    assert_receive {:respawn, "architect"}, 1_000

    # Mort ULTÉRIEURE (après succès) → le compteur est reparti de zéro → re-respawn direct.
    send(warden, pod_failed("permanent-architect"))
    assert_receive {:respawn, "architect"}, 1_000
  end

  test "pod.failed d'un pod NON-permanent (issue-*) → no-op (la relance = job du rail forge)" do
    parent = self()
    warden = start_warden(fn role -> send(parent, {:respawn, role}) && {:ok, role} end)

    send(warden, pod_failed("fleet-poc-issue-3-engineer"))
    refute_receive {:respawn, _}, 100
  end

  test "respawn qui ÉCHOUE → retry (backoff) puis HALT à la borne (dépense bornée, pas de churn)" do
    parent = self()

    warden =
      start_warden(fn role ->
        send(parent, {:respawn_attempt, role})
        {:error, {role, :launch_failed}}
      end)

    send(warden, pod_failed("permanent-architect"))

    # Borne @max_attempts = 5 tentatives EXÉCUTÉES (1 déclenchée par l'event + 4 retries d'échec) ;
    # le 5e échec constate la borne → HALT.
    for _ <- 1..5 do
      assert_receive {:respawn_attempt, "architect"}, 1_000
    end

    # Borne atteinte → HALT : plus AUCUNE tentative (dépense bornée, l'escalade incident a déjà eu lieu).
    refute_receive {:respawn_attempt, _}, 300
  end

  test "pod.failed POST-HALT = réparation externe détectée → NOUVEAU cycle (cattle, E2)" do
    parent = self()

    warden =
      start_warden(fn role ->
        send(parent, {:respawn_attempt, role})
        {:error, {role, :launch_failed}}
      end)

    # Épuise la borne (1 event + 4 retries = 5 tentatives) → HALT.
    send(warden, pod_failed("permanent-architect"))
    for _ <- 1..5, do: assert_receive({:respawn_attempt, "architect"}, 1_000)
    refute_receive {:respawn_attempt, _}, 200

    # Un pod.failed POST-HALT ne peut venir que d'un pod RESSUSCITÉ par un acteur externe
    # (le warden ne respawn plus) → le warden repart pour un nouveau cycle au lieu de rester
    # mort pour ce rôle jusqu'au restart BEAM.
    send(warden, pod_failed("permanent-architect"))
    assert_receive {:respawn_attempt, "architect"}, 1_000
  end

  test "backoff_delay/2 : exponentiel plafonné, pur" do
    assert PermanentWarden.backoff_delay(0, 5_000) == 5_000
    assert PermanentWarden.backoff_delay(1, 5_000) == 10_000
    assert PermanentWarden.backoff_delay(3, 5_000) == 40_000
    # plafond 10 min
    assert PermanentWarden.backoff_delay(10, 5_000) == 600_000
    # ne déborde jamais (exposant clampé)
    assert PermanentWarden.backoff_delay(1_000_000, 5_000) == 600_000
  end
end

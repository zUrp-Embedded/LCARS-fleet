defmodule Fleet.Spawner.PermanentWardenTest do
  @moduledoc """
  G5 — respawn des permanents morts. Seams : `subscribe: false` (pas de Bus réel — on envoie les
  events directement au process), `respawn_fun` stub, `backoff_base_ms: 1` (delais ~ms, test rapide).
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.PermanentWarden

  defp start_warden(respawn_fun, opts \\ []) do
    start_supervised!(
      {PermanentWarden,
       [name: nil, subscribe: false, respawn_fun: respawn_fun, backoff_base_ms: 1] ++ opts}
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

  test "pod.failed d'un permanent → respawn (via backoff) ; mort SOUS min-uptime → le compteur CONTINUE" do
    parent = self()

    warden =
      start_warden(fn role ->
        send(parent, {:respawn, role})
        {:ok, "permanent-#{role}"}
      end)

    send(warden, pod_failed("permanent-architect"))
    # backoff_base 1ms → le respawn planifié arrive vite.
    assert_receive {:respawn, "architect"}, 1_000

    # Mort quasi-immédiate (sous min_uptime défaut 60s) : PAS de reset au {:ok, pid} du
    # start_child (la chaîne launch est async — boote-puis-meurt bouclait à l'infini sur un
    # reset-at-start). Le cycle continue, borné : le respawn arrive encore (attempt 2/5).
    send(warden, pod_failed("permanent-architect"))
    assert_receive {:respawn, "architect"}, 1_000
  end

  test "survie OBSERVÉE (min_uptime_ms: 0) → compteur remis à zéro : jamais de HALT sur des morts espacées" do
    parent = self()

    warden =
      start_warden(
        fn role ->
          send(parent, {:respawn, role})
          {:ok, "permanent-#{role}"}
        end,
        min_uptime_ms: 0
      )

    # 7 cycles mort→respawn (> @max_attempts=5) : avec min_uptime 0, chaque uptime compte
    # comme une survie → reset à chaque mort → la borne n'est jamais atteinte (sémantique
    # « une mort ULTÉRIEURE repart d'un backoff court » préservée pour les pods sains).
    for _ <- 1..7 do
      send(warden, pod_failed("permanent-architect"))
      assert_receive {:respawn, "architect"}, 1_000
    end
  end

  test "boote-puis-meurt en boucle (launch OK, mort sous min-uptime) → HALT DURABLE, dépense bornée" do
    parent = self()

    warden =
      start_warden(fn role ->
        send(parent, {:respawn, role})
        {:ok, "permanent-#{role}"}
      end)

    # Chaque respawn RÉUSSIT (start_child {:ok}) mais le pod meurt sous min_uptime (60s défaut,
    # le test tourne en ms) : le compteur doit CONTINUER malgré les {:ok} → borne à 5 respawns.
    for _ <- 1..5 do
      send(warden, pod_failed("permanent-architect"))
      assert_receive {:respawn, "architect"}, 1_000
    end

    # 6e mort sous min-uptime avec la borne épuisée → HALT RÉEL : plus aucun respawn,
    # même sur les morts suivantes (le HALT est durable tant qu'aucune survie n'est observée).
    send(warden, pod_failed("permanent-architect"))
    refute_receive {:respawn, _}, 300

    send(warden, pod_failed("permanent-architect"))
    refute_receive {:respawn, _}, 300
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

  # ── Rail 2 : réconciliation (le rail event est AVEUGLE aux morts silencieuses) ──

  test "tick de réconciliation : un permanent ABSENT du Registry (aucun pod.failed émis) → respawn" do
    # Un restart du sous-arbre spawner termine ses pods :temporary PROPREMENT → zéro pod.failed →
    # le warden (purement event-driven) ne voyait RIEN et les permanents restaient morts en
    # silence jusqu'à une escalade. Le tick re-dérive la vérité : attendus vs Registry vivant.
    parent = self()

    warden =
      start_warden(
        fn role ->
          send(parent, {:respawn, role})
          {:ok, "permanent-#{role}"}
        end,
        reconcile_ms: 10,
        expected_roles_fun: fn -> ["architect", "gatekeeper"] end,
        # gatekeeper vivant, architect DISPARU sans event.
        live_roles_fun: fn -> ["gatekeeper"] end
      )

    assert_receive {:respawn, "architect"}, 1_000
    refute_received {:respawn, "gatekeeper"}
    assert Process.alive?(warden)
  end

  test "tick de réconciliation : boot permanent DÉSACTIVÉ (maintenance) → aucun respawn" do
    # Le mode maintenance documenté (LCARS_BOOT_PERMANENT_AT_START=false) ne doit pas être
    # défait par un warden qui re-dérive des pods que personne n'a demandés.
    parent = self()

    start_warden(
      fn role -> send(parent, {:respawn, role}) && {:ok, "permanent-#{role}"} end,
      reconcile_ms: 10,
      expected_roles_fun: fn -> ["architect"] end,
      live_roles_fun: fn -> [] end,
      reconcile_enabled_fun: fn -> false end
    )

    refute_receive {:respawn, _}, 200
  end

  test "tick de réconciliation : énumération qui LÈVE → rien respawné (le filet ne devient jamais un danger)" do
    # Une énumération cassée (Registry indispo, catalogue illisible) ne doit NI tuer le warden,
    # NI — pire — rapporter TOUS les permanents comme absents et re-spawner la flotte entière.
    parent = self()

    warden =
      start_warden(
        fn role -> send(parent, {:respawn, role}) && {:ok, "permanent-#{role}"} end,
        reconcile_ms: 10,
        expected_roles_fun: fn -> raise "catalogue illisible" end,
        live_roles_fun: fn -> [] end
      )

    refute_receive {:respawn, _}, 200
    assert Process.alive?(warden)
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

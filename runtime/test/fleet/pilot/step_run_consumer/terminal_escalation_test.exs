defmodule Fleet.Pilot.StepRunConsumer.TerminalEscalationTest do
  @moduledoc """
  CI-04 — WAKE-AFTER-COMMIT. `freeze_to_arch` must offer-then-wake the arch ONLY after `await_arch`
  returns a confirmed commit (`{:ok, _}`), and INSIDE the same `run_completion` unit (in prod this
  unit is offloaded onto a Task.Supervisor and returns `{:ok, :offloaded}` at once — an offer placed
  outside it would fire before the forge writes, or on a synchronous `{:error, _}`, waking the arch
  onto a mandate that does not exist yet). We drive `freeze_to_arch/5` directly with a sync
  `run_completion` and a stub completer, and assert the offer-then-wake fires on commit and is
  SUPPRESSED on failure.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Fleet.Pilot.StepRunConsumer.TerminalEscalation
  alias Fleet.Pilot.StepRunConsumer.TerminalEscalation.Seams
  alias Fleet.Pilot.StubTaskQueue

  defmodule OkCompleter do
    def await_arch(step_run, _opts) do
      send(self(), {:await_arch, step_run})
      {:ok, :awaiting_arch}
    end
  end

  defmodule FailCompleter do
    def await_arch(step_run, _opts) do
      send(self(), {:await_arch, step_run})
      {:error, {:await_arch, {:http, 500, "comment boom"}}}
    end
  end

  defmodule StubSpawner do
    def wake_pod(pod_id) do
      send(self(), {:wake, pod_id})
      :ok
    end

    # ProjectArchitect.ensure (default, on-demand) → best-effort spawn; captured, never blocking.
    def spawn_pod(_cap, pod_id, _opts) do
      send(self(), {:spawned, pod_id})
      {:ok, self()}
    end
  end

  # SYNC run_completion (prod offloads onto a Task.Supervisor; the sync default runs the closure
  # inline and returns its outcome — the discipline under test is the ORDER, identical either way).
  defp seams(completer),
    do: %Seams{
      repo: "o/r",
      step_run_completer: completer,
      completer_opts: [forge_opts: []],
      spawner: StubSpawner,
      task_queue: StubTaskQueue,
      run_completion: fn _label, fun -> fun.() end
    }

  test "await_arch COMMITS → offer-then-wake fires (mandate enqueued THEN wake), outcome bubbles up" do
    capture_log(fn ->
      assert {:ok, :awaiting_arch} =
               TerminalEscalation.freeze_to_arch(
                 7,
                 "engineer",
                 :terminal_error,
                 "body",
                 seams(OkCompleter)
               )
    end)

    assert_received {:await_arch, %{issue_number: 7}}

    # ArchWake enqueues the arbitration mandate BEFORE waking (per-project arch pod "architect-r").
    assert_received {:enqueued, "architect-r", _attrs}
    assert_received {:wake, "architect-r"}
  end

  test "await_arch FAILS → NO offer, NO wake (arch never woken onto a non-existent mandate), error bubbles up" do
    capture_log(fn ->
      assert {:error, {:await_arch, {:http, 500, "comment boom"}}} =
               TerminalEscalation.freeze_to_arch(
                 7,
                 "engineer",
                 :terminal_error,
                 "body",
                 seams(FailCompleter)
               )
    end)

    assert_received {:await_arch, %{issue_number: 7}}

    # The escalation did NOT commit → the offer-then-wake is suppressed entirely (CI-04): the Poller
    # net re-derives a wake next tick from the durable forge state, if any took.
    refute_received {:enqueued, "architect-r", _attrs}
    refute_received {:wake, "architect-r"}
    refute_received {:spawned, "architect-r"}
  end

  # 6-084 — LA BRANCHE `notify_pod` JETAIT SON RESULTAT, et le `@doc` de `kick_architect` annonce
  # « Failures are logged » — ce qui n'etait vrai que de l'AUTRE branche. C'est le chemin d'escalade
  # TERMINALE : le dernier avertissement d'un ticket mort. Pod de l'architecte absent du Registry,
  # message perdu, et rien ne le disait — ni dans les journaux, ni dans le retour (`:ok` par
  # contrat, et il le reste : ce chemin est non-bloquant par conception).
  defmodule AbsentArchSpawner do
    def wake_pod(pod_id) do
      send(self(), {:wake, pod_id})
      :ok
    end

    def spawn_pod(_cap, pod_id, _opts) do
      send(self(), {:spawned, pod_id})
      {:ok, self()}
    end

    def notify_pod(pod_id, _msg) do
      send(self(), {:notify, pod_id})
      {:error, :not_found}
    end
  end

  defmodule LiveArchSpawner do
    def wake_pod(pod_id) do
      send(self(), {:wake, pod_id})
      :ok
    end

    def spawn_pod(_cap, pod_id, _opts) do
      send(self(), {:spawned, pod_id})
      {:ok, self()}
    end

    def notify_pod(pod_id, _msg) do
      send(self(), {:notify, pod_id})
      :ok
    end
  end

  describe "6-084 — un architecte injoignable ne se perd plus en silence" do
    test "notify en echec -> `error` qui nomme le pod, le depot, et ce qui NE rattrape pas" do
      log =
        capture_log(fn ->
          assert :ok = TerminalEscalation.kick_architect(AbsentArchSpawner, "o/r", "verdict")
        end)

      assert_received {:notify, "architect-r"}

      assert log =~ "architect-r"
      assert log =~ "o/r"
      assert log =~ "INJOIGNABLE"

      # `error` et non `warning` : doctrine des niveaux du depot — perte REELLE = `error`. Ce qui
      # vient d'etre perdu est le dernier avertissement d'un ticket mort.
      assert log =~ "[error]"

      # Et la trace doit dire ce qui SURVIT, sinon elle transforme une perte bornee en panique :
      # l'incident reste dans le registre et l'issue forge, seule la notification est perdue.
      assert log =~ "registre"
    end

    test "TEMOIN — notify qui passe : aucun `error`, le chemin nominal reste muet" do
      # Sans lui, un `Logger.error` inconditionnel passerait le test precedent et remplirait le
      # journal d'une escalade reussie sur deux.
      log =
        capture_log(fn ->
          assert :ok = TerminalEscalation.kick_architect(LiveArchSpawner, "o/r", "verdict")
        end)

      assert_received {:notify, "architect-r"}
      refute log =~ "INJOIGNABLE"
    end

    test "le retour reste `:ok` — ce chemin est non-bloquant par contrat, et le reste" do
      # Elever le fait au journal ne doit PAS transformer une escalade ratee en erreur remontante :
      # le consommateur qui l'appelle est en train de clore un step_run mort, et le faire echouer
      # la-dessus perdrait AUSSI le reste de la cloture.
      capture_log(fn ->
        assert :ok = TerminalEscalation.kick_architect(AbsentArchSpawner, "o/r", "verdict")
      end)
    end
  end
end

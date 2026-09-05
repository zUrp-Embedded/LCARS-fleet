defmodule Fleet.Pilot.StepRunConsumer.VerdictCorrectionTest do
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepRunConsumer.VerdictCorrection

  @moduledoc """
  B4 — UNE passe de correction d'enveloppe, et une seule.

  `async: false` : le drapeau d'auto-gating (`:pilot_verdict_correction_pass?`) est global au nœud.
  """

  # ── Coutures ───────────────────────────────────────────────────────────────────────────────────

  defmodule Forge do
    @moduledoc false
    def count_comments_marked(_r, _n, marker, _o) do
      send(self(), {:counted, marker})
      {:ok, :persistent_term.get({__MODULE__, :spent}, 0)}
    end

    def post_comment(_r, n, body, opts) do
      send(self(), {:marker, n, body, opts[:dedup_signature]})
      {:ok, :posted}
    end
  end

  defmodule ForgeMarkerFails do
    @moduledoc false
    def count_comments_marked(_r, _n, _m, _o), do: {:ok, 0}
    def post_comment(_r, _n, _b, _o), do: {:error, :boom}
  end

  defmodule ForgeCountUnreadable do
    @moduledoc false
    def count_comments_marked(_r, _n, _m, _o), do: {:error, :unreachable}

    def post_comment(_r, _n, _b, _o) do
      send(self(), :posted_anyway)
      {:ok, :posted}
    end
  end

  defmodule Queue do
    @moduledoc false
    def enqueue(pod_id, attrs) do
      send(self(), {:enqueued, pod_id, attrs})
      {:ok, :t}
    end
  end

  defmodule QueueFails do
    @moduledoc false
    def enqueue(_pod_id, _attrs), do: {:error, :full}
  end

  defmodule Spawner do
    @moduledoc false
    def wake_pod(pod_id) do
      send(self(), {:woken, pod_id})
      :ok
    end
  end

  defmodule Completer do
    @moduledoc false
    def await_arch(step_run, _opts) do
      send(self(), {:frozen, step_run.comment_body})
      {:ok, :awaiting}
    end
  end

  defp seams(forge \\ Forge, queue \\ Queue) do
    %VerdictCorrection.Seams{
      repo: "fleet/proj",
      forge: forge,
      forge_opts: [],
      task_queue: queue,
      spawner: Spawner,
      terminal: %Fleet.Pilot.StepRunConsumer.TerminalEscalation.Seams{
        repo: "fleet/proj",
        step_run_completer: Completer,
        completer_opts: [],
        spawner: Spawner,
        task_queue: Queue,
        run_completion: fn _label, fun -> fun.() end
      }
    }
  end

  setup do
    :persistent_term.put({Forge, :spent}, 0)
    on_exit(fn -> :persistent_term.erase({Forge, :spent}) end)
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_verdict_correction_pass?, true)
    :ok
  end

  defp request(seams \\ nil),
    do:
      VerdictCorrection.request(
        42,
        "qualifier",
        "#/details: expected Object",
        "trace du verdict",
        seams || seams()
      )

  # ── La porte, pure ─────────────────────────────────────────────────────────────────────────────

  describe "decision/1 — une passe, puis l'architecte" do
    test "zéro dépensée → on corrige ; une → on escalade" do
      assert VerdictCorrection.decision({:ok, 0}) == :correct
      assert VerdictCorrection.decision({:ok, 1}) == :escalate
      assert VerdictCorrection.decision({:ok, 7}) == :escalate
    end

    test "compte ILLISIBLE → escalade, jamais une passe de plus" do
      # ⚠ LA DIRECTION EST LE POINT. Ne pas savoir combien de passes ont été dépensées ne doit
      # jamais en acheter une : c'est le choix qu'ont déjà fait les deux autres échelles, et c'est
      # ce qui empêche une forge muette de rendre la boucle illimitée.
      assert VerdictCorrection.decision({:error, :unreachable}) == :escalate
      assert VerdictCorrection.decision(:n_importe_quoi) == :escalate
    end
  end

  # ── Le chemin nominal ──────────────────────────────────────────────────────────────────────────

  describe "la passe" do
    test "marqueur POSÉ, brief au pod VIVANT, réveil — et le motif voyage" do
      assert {:ok, :correction_requested} = request()

      assert_received {:counted, "[verdict-correction:issue-42"}
      assert_received {:marker, 42, body, "[verdict-correction:issue-42:round-1]"}

      # Une demande de correction qui ne dit pas ce qui clochait est une demande de deviner.
      assert body =~ "#/details: expected Object"

      # LE POD EST CELUI QUI EST DÉJÀ LÀ, et l'id se construit comme au dispatch — un juge d'étape
      # est minté sur le TICKET, pas sur une PR.
      assert_received {:enqueued, pod_id, attrs}
      assert pod_id == Fleet.PodId.for_issue("fleet/proj", 42, "qualifier")
      assert attrs.metadata["verdict_correction"] == "round-1"
      assert attrs.brief =~ "#/details: expected Object"

      # Ce que le brief interdit explicitement : refaire l'analyse.
      assert attrs.brief =~ "Ne refais pas ton analyse"

      assert_received {:woken, ^pod_id}
    end

    test "passe DÉJÀ dépensée → gel, et le gel dit pourquoi" do
      :persistent_term.put({Forge, :spent}, 1)

      assert {:ok, :awaiting} = request()

      refute_received {:enqueued, _, _}
      assert_received {:frozen, body}
      assert body =~ "correction_pass_spent"
      # La trace du verdict n'est pas perdue en route : l'architecte lit les deux.
      assert body =~ "trace du verdict"
    end
  end

  # ── Les échecs, et leur direction ──────────────────────────────────────────────────────────────

  describe "ce qui ne doit JAMAIS acheter une passe de plus" do
    test "marqueur NON posé → aucune correction : une passe non enregistrée est illimitée" do
      # ⚠ LE MARQUEUR EST LE BUDGET. Corriger sans avoir réussi à l'écrire ferait lire zéro marqueur
      # au tick suivant, donc redemander, indéfiniment. Même leçon, mot pour mot, que le barreau
      # d'arbitrage de la zone grise.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :awaiting} = request(seams(ForgeMarkerFails))
        end)

      refute_received {:enqueued, _, _}
      assert log =~ "an unrecorded pass is an unbounded one"
    end

    test "compte illisible → gel SANS même poser le marqueur" do
      assert {:ok, :awaiting} = request(seams(ForgeCountUnreadable))

      refute_received :posted_anyway
      refute_received {:enqueued, _, _}
      assert_received {:frozen, body}
      assert body =~ "correction_pass_spent"
    end

    test "marqueur posé mais brief NON parti → gel, et le motif ne ment pas sur ce qui s'est passé" do
      # Une passe comptée sans avoir été jouée. Réessayer plus tard lirait le marqueur et
      # escaladerait en disant « déjà dépensée » là où rien n'avait été demandé — donc on gèle tout
      # de suite, avec le vrai motif.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :awaiting} = request(seams(Forge, QueueFails))
        end)

      assert_received {:frozen, body}
      assert body =~ "correction_undispatchable"
      assert log =~ "freezing rather than reporting a pass that never ran"
    end
  end

  # ── L'auto-gating ──────────────────────────────────────────────────────────────────────────────

  describe "le barreau est ÉTEINT par défaut" do
    test "désarmé → gel, et l'escalade NOMME le barreau non armé" do
      # ⚠ CE N'EST PAS UN NO-OP SILENCIEUX, et la distinction sert un humain : un architecte qui lit
      # le gel doit pouvoir dire « la passe a échoué » de « la passe n'est pas armée sur ce
      # conteneur ». Un mécanisme jamais joué de bout en bout sur un banc est une hypothèse.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_verdict_correction_pass?, false)

      assert {:ok, :awaiting} = request()

      refute_received {:counted, _}
      refute_received {:enqueued, _, _}
      assert_received {:frozen, body}
      assert body =~ "correction_pass_disabled"
    end
  end
end

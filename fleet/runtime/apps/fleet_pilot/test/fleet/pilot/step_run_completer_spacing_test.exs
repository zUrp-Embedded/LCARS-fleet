defmodule Fleet.Pilot.StepRunCompleterSpacingTest do
  # async: false — mute la config globale `:step_run_write_spacing_ms` (cf. Fleet.Credentials.RoleTokenTest).
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepRunCompleter

  # F-E7 — stub forge qui MARQUE l'ordre de chaque écriture ; le seam `:sleeper` marque le gap. On vérifie
  # que le gap est INSÉRÉ entre le commentaire de verdict et la route (sinon même seconde → tie dashboard).
  defmodule SeqForge do
    def post_comment(_r, _n, _b, _o), do: tag(:comment)
    def post_route(_r, _n, _p, _s, _o), do: tag(:route)
    def close_issue(_r, _n, _o), do: tag(:close)
    def remove_label(_r, _n, _l, _o), do: tag(:unlock)
    def add_label(_r, _n, _l, _o), do: tag(:label)

    def start_stopwatch(_r, _n, _o) do
      send(self(), {:call, :sw_start})
      :ok
    end

    def stop_stopwatch(_r, _n, _o) do
      send(self(), {:call, :sw_stop})
      :ok
    end

    defp tag(t) do
      send(self(), {:call, t})
      {:ok, t}
    end
  end

  defp drain do
    receive do
      {:call, t} -> [t | drain()]
    after
      0 -> []
    end
  end

  defp set_spacing(ms),
    do: Fleet.Pilot.TestEnv.put_env_restoring(:fleet_pilot, :step_run_write_spacing_ms, ms)

  test "complete : le gap configuré est INSÉRÉ entre le comment de verdict et la route" do
    set_spacing(2000)

    step_run = %{
      repo: "fleet/poc",
      issue_number: 1,
      role: "consultant",
      deliverable_opts: nil,
      step_run_sha: "brief-verdict",
      next_assignee: "build",
      workflow_map: "poc",
      next_step: "build",
      comment_body: "Verdict du consultant — continue"
    }

    # seam `:sleeper` → on ne dort PAS réellement, on capture la durée demandée (déterministe).
    sleeper = fn ms -> send(self(), {:call, {:slept, ms}}) end

    assert {:ok, :reassigned} =
             StepRunCompleter.complete(step_run,
               forge_client: SeqForge,
               forge_opts: [],
               sleeper: sleeper
             )

    # ordre : comment AVANT le gap (2s) AVANT la route → plus de tie même-seconde à l'affichage.
    assert [:comment, {:slept, 2000}, :route | _] = drain()
  end

  test "spacing 0 (défaut test) → AUCUN gap (pas de sleep parasite dans la suite)" do
    set_spacing(0)

    step_run = %{
      repo: "fleet/poc",
      issue_number: 1,
      role: "consultant",
      deliverable_opts: nil,
      step_run_sha: "brief-verdict",
      next_assignee: nil,
      comment_body: "Verdict du consultant — abandon"
    }

    sleeper = fn ms -> send(self(), {:call, {:slept, ms}}) end

    assert {:ok, :completed} =
             StepRunCompleter.complete(step_run,
               forge_client: SeqForge,
               forge_opts: [],
               sleeper: sleeper
             )

    # terminal (next_assignee nil → close) : comment puis close, et SURTOUT aucun {:slept, _}.
    seq = drain()
    assert :comment in seq
    refute Enum.any?(seq, &match?({:slept, _}, &1))
  end

  # F-QoL (2026-07-07) — flux producteur : la NOTE COMPLÈTE (issue) doit être POSTÉE AVANT la transition
  # de stage (mutex `stage/build`→`stage/review`) — même doctrine « comment PUIS stage », même gap, que
  # `complete/2` (consultant). Sans lui : l'ordre observé sur le dashboard forge était INVERSÉ (stage posé
  # avant le comment, alors que le code posait déjà le comment logiquement en premier — tie même-seconde).
  defmodule ProducerSeqForge do
    def open_pr(_repo, _head, _base, _title, _opts),
      do:
        (
          send(self(), {:call, :open_pr})
          {:ok, 7}
        )

    def post_comment(_repo, _n, _body, _opts),
      do:
        (
          send(self(), {:call, :comment})
          {:ok, :posted}
        )

    def set_stage(_repo, _n, _stage, _opts),
      do:
        (
          send(self(), {:call, :stage})
          {:ok, :posted}
        )

    def request_review(_repo, _pr, _reviewers, _opts),
      do:
        (
          send(self(), {:call, :request_review})
          :ok
        )

    def post_route(_repo, _n, _p, _s, _opts),
      do:
        (
          send(self(), {:call, :route})
          {:ok, :posted}
        )

    def remove_label(_repo, _n, _label, _opts),
      do:
        (
          send(self(), {:call, :unlock})
          {:ok, :removed}
        )

    def stop_stopwatch(_repo, _n, _opts), do: :ok
  end

  defmodule StubDeliverable do
    def publish(_opts), do: {:ok, %{commit_sha: "deadbeef", pushed?: true, mode: :git_native}}
  end

  test "complete_pr producteur :advance — le gap est INSÉRÉ entre le comment (note eng) et la transition de stage" do
    set_spacing(2000)

    step_run = %{
      repo: "fleet/proj",
      issue_number: 42,
      role: "engineer",
      pr_role: :producer,
      intent: :advance,
      next_assignee: "qualifier",
      producer_branch: "lcars/issue-42-engineer",
      eng_summary: "j'ai implémenté le décodeur",
      deliverable_opts: %{
        mode: :git_native,
        workspace: "/tmp/ws",
        base_sha: "cafe",
        target_branch: "lcars/issue-42-engineer"
      }
    }

    sleeper = fn ms -> send(self(), {:call, {:slept, ms}}) end

    assert {:ok, :review_requested} =
             StepRunCompleter.complete_pr(step_run,
               deliverable: StubDeliverable,
               forge_client: ProducerSeqForge,
               forge_opts: [],
               sleeper: sleeper
             )

    # ordre : le comment (note eng, POINTEUR déjà plié dans open_pr) AVANT le gap AVANT la transition de
    # stage — plus de tie même-seconde (le stage n'apparaît plus AVANT le comment sur le dashboard).
    assert [:open_pr, :comment, {:slept, 2000}, :stage | _] = drain()
  end

  # F-QoL (2026-07-07) — flux PROMOTE (merge, déclenché par le DERNIER juge) : le sceau (merge + comment
  # + `stage/merged`) doit être VISIBLEMENT antérieur à l'unlock (`lcars-in-flight` retiré, sur la PR —
  # verrou juge) — même risque de tie même-seconde que ci-dessus, cette fois entre deux écritures de
  # LABEL de familles distinctes (cf. `Fleet.Pilot.Labels`).
  defmodule PromoteSeqForge do
    def get_pr_for_branch(_repo, _head, _base, _opts),
      do:
        (
          send(self(), {:call, :get_pr})
          {:ok, 7}
        )

    def post_review(_repo, _pr, _event, _body, _opts),
      do:
        (
          send(self(), {:call, :review})
          :ok
        )

    def merge_pr(_repo, _pr, _opts),
      do:
        (
          send(self(), {:call, :merge})
          :ok
        )

    def post_comment(_repo, _n, _body, _opts),
      do:
        (
          send(self(), {:call, :comment})
          {:ok, :posted}
        )

    def set_stage(_repo, _n, _stage, _opts),
      do:
        (
          send(self(), {:call, :stage})
          {:ok, :posted}
        )

    def close_issue(_repo, _n, _opts), do: {:ok, :closed}

    def remove_label(_repo, _n, _label, _opts),
      do:
        (
          send(self(), {:call, :unlock})
          {:ok, :removed}
        )

    def stop_stopwatch(_repo, _n, _opts), do: :ok
  end

  test "complete_pr juge :promote — le gap est INSÉRÉ entre le sceau (merge+stage) et l'unlock" do
    set_spacing(2000)

    step_run = %{
      repo: "fleet/proj",
      issue_number: 42,
      pr_role: :judge,
      intent: :promote,
      role: "reviewer",
      producer_branch: "lcars/issue-42-engineer"
    }

    sleeper = fn ms -> send(self(), {:call, {:slept, ms}}) end

    assert {:ok, :promoted} =
             StepRunCompleter.complete_pr(step_run,
               forge_client: PromoteSeqForge,
               forge_opts: [],
               sleeper: sleeper
             )

    seq = drain()
    slept_idx = Enum.find_index(seq, &match?({:slept, 2000}, &1))
    unlock_idx = Enum.find_index(seq, &(&1 == :unlock))
    assert is_integer(slept_idx) and is_integer(unlock_idx) and slept_idx < unlock_idx
    assert :merge in seq
    assert :stage in seq
  end
end

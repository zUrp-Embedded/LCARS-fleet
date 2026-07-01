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

  defp set_spacing(ms) do
    prev = Application.get_env(:fleet_pilot, :step_run_write_spacing_ms)
    Application.put_env(:fleet_pilot, :step_run_write_spacing_ms, ms)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:fleet_pilot, :step_run_write_spacing_ms, prev),
        else: Application.delete_env(:fleet_pilot, :step_run_write_spacing_ms)
    end)
  end

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
end

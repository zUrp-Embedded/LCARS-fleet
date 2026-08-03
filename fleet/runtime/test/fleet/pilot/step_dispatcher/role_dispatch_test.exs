defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatchTest do
  @moduledoc """
  BL-6-47.2 — a jury role that does not RESOLVE used to return a bare `{:skipped, :no_role}`, with
  no trace of any kind. That made a TYPO in a card indistinguishable from a step that legitimately
  carries no judge; and because the second case is ordinary, nobody looks. One missing letter froze
  a brick, in silence, on every tick, while the PR kept displaying "judge at work".

  What these tests pin is the DISTINCTION, not the logging: an empty role stays silent (saying it
  every 30 s would train an operator to skip the line the other clause emits), an unresolvable role
  reaches the incident rail — keyed on the ROLE, so one typo seen on ten PRs is one incident and
  not ten sysadmin issues.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch

  defmodule Loader do
    # Only `reviewer` resolves. Anything else is the shape of a card typo.
    def load("reviewer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => "reviewer"},
           spec: %{"brief_kind" => "judge"}
         }}

    def load(_), do: {:error, :not_found}
  end

  defp ctx(extra_opts) do
    %Ctx{
      forge: __MODULE__.UnusedForge,
      loader: Loader,
      workflow_map_loader: fn _ -> %{} end,
      spawner: __MODULE__.UnusedSpawner,
      task_queue: __MODULE__.UnusedQueue,
      resolver: fn _repo, _opts -> {:ok, nil} end,
      repo: "acme/widget",
      forge_opts: [],
      wake_recovery: fn _, _, _ -> :ok end,
      opts: extra_opts
    }
  end

  # The incident seam reports into the test process — the flow must call it, and with WHAT.
  defp spy,
    do: fn op, subject, reason, opts -> send(self(), {:incident, op, subject, reason, opts}) end

  @head "lcars/issue-42-reviewer"

  test "role UNRESOLVABLE → skip AND an incident, keyed on the ROLE" do
    # Le coeur du defaut : avant, ce chemin ne produisait rien du tout.
    assert {:skipped, :no_role} =
             RoleDispatch.dispatch(:judge, 7, @head, "revieweer", ctx(incident_fun: spy()))

    assert_received {:incident, "review_role", "revieweer", :cap_profile_unresolvable, opts}
    # Le detail porte le depot : l'incident est cle sur le ROLE, mais un humain doit savoir OU.
    assert Keyword.get(opts, :reason_detail) =~ "acme/widget"
  end

  test "role VIDE → skip SILENCIEUX : un step sans juge est une configuration ordinaire" do
    # La distinction qui compte. Si l'absence de juge criait aussi, la ligne du cas fautif se
    # noierait dans des milliers de lignes legitimes — et un garde qu'on apprend a ignorer ne garde
    # plus rien.
    assert {:skipped, :no_role} =
             RoleDispatch.dispatch(:judge, 7, @head, "", ctx(incident_fun: spy()))

    refute_received {:incident, _, _, _, _}
  end

  test "branche non-fleet → skip AVANT toute resolution de role (aucun incident)" do
    # Une PR etrangere n'est pas une anomalie : elle ne doit pas peupler le registre d'incidents.
    assert {:skipped, :not_fleet_branch} =
             RoleDispatch.dispatch(
               :judge,
               7,
               "refs/pull/6/head",
               "revieweer",
               ctx(incident_fun: spy())
             )

    refute_received {:incident, _, _, _, _}
  end

  test "un rail d'incident MORT ne casse pas le dispatch — le skip tient, sa trace est dite perdue" do
    # never-stall : l'incident est un rail d'observation, jamais une condition de la decision.
    boom = fn _op, _subject, _reason, _opts -> raise "registre indisponible" end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:skipped, :no_role} =
                 RoleDispatch.dispatch(:judge, 7, @head, "revieweer", ctx(incident_fun: boom))
      end)

    assert log =~ "StepDispatcher: incident rail unavailable"
    assert log =~ "revieweer"
  end
end

defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatchTest do
  @moduledoc """
  Empty roles skip silently; failed resolution reports an incident keyed by role with
  repository detail. The injected callback checks arguments, not registry deduplication.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch

  defmodule Loader do
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

  defp spy,
    do: fn op, subject, reason, opts -> send(self(), {:incident, op, subject, reason, opts}) end

  @head "lcars/issue-42-reviewer"

  test "role UNRESOLVABLE → skip AND an incident, keyed on the ROLE" do
    assert {:skipped, :no_role} =
             RoleDispatch.dispatch(:judge, 7, @head, "revieweer", ctx(incident_fun: spy()))

    assert_received {:incident, "review_role", "revieweer", :cap_profile_unresolvable, opts}

    assert Keyword.get(opts, :reason_detail) =~ "acme/widget"
  end

  test "role VIDE → skip SILENCIEUX : un step sans juge est une configuration ordinaire" do
    assert {:skipped, :no_role} =
             RoleDispatch.dispatch(:judge, 7, @head, "", ctx(incident_fun: spy()))

    refute_received {:incident, _, _, _, _}
  end

  test "branche non-fleet → skip AVANT toute resolution de role (aucun incident)" do
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

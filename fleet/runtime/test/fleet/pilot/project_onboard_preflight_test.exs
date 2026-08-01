defmodule Fleet.Pilot.ProjectOnboardPreflightTest do
  @moduledoc """
  F2: preflight `ensure_human_provisioned` BEFORE any creation. Contracts tested: PROVEN absence of
  account/team → error with the EXACT admin gestures; forge DOWN → :forge_preflight_failed WITHOUT
  instructions (we never send the operator to create an account on an outage); provisioned human →
  the preflight is transparent (the sequence continues). :forge_users seam — no network.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Fleet.Pilot.ProjectOnboard

  defmodule OkUsers do
    def user_exists?(_u, _fc), do: {:ok, true}
    def team_member?(_org, "humans", _u, _fc), do: {:ok, true}
  end

  defmodule NoAccountUsers do
    def user_exists?(_u, _fc), do: {:ok, false}
    def team_member?(_org, _t, _u, _fc), do: raise("must not be reached")
  end

  defmodule NoTeamUsers do
    def user_exists?(_u, _fc), do: {:ok, true}
    def team_member?(_org, "humans", _u, _fc), do: {:ok, false}
  end

  defmodule DownForge do
    def user_exists?(_u, _fc), do: {:error, {:transport, :econnrefused}}
    def team_member?(_org, _t, _u, _fc), do: {:error, {:transport, :econnrefused}}
  end

  defmodule ForbiddenTeamUsers do
    # Account OK, but the runtime token can NOT read team membership (403): real forge case —
    # the service account is a plain org member (neither owner nor member of `humans`),
    # Gitea refuses GET /teams/<id>/members/<u>. "Cannot verify" ≠ "human absent".
    def user_exists?(_u, _fc), do: {:ok, true}

    def team_member?(_org, "humans", _u, _fc),
      do: {:error, {:http, 403, %{"message" => "Forbidden"}}}
  end

  # The human's OWN token path: the runtime must ask `self_team_member?` (about the authenticated
  # account) and NEVER `team_member?` (about a third party). `team_member?` here raises: if the
  # preference silently fell back, the test would not merely fail, it would say why.
  defmodule SelfUsers do
    def user_exists?(_u, _fc), do: {:ok, true}
    def self_team_member?(_org, "humans", fc), do: {:ok, Keyword.has_key?(fc, :token_file)}

    def team_member?(_org, _team, _u, _fc),
      do: raise("team_member? called while the human token was available")
  end

  defmodule SelfDeniesUsers do
    def user_exists?(_u, _fc), do: {:ok, true}
    def self_team_member?(_org, "humans", _fc), do: {:ok, false}
  end

  defp opts(tmp, users),
    do: [
      human: "ghost-human",
      forge_users: users,
      projects_root: Path.join(tmp, "projects"),
      work_root: Path.join(tmp, "work")
    ]

  @tag :tmp_dir
  test "forge account absent → human_not_provisioned + exact admin gestures (account)", %{
    tmp_dir: tmp
  } do
    assert {:error, {:human_not_provisioned, "ghost-human", gestures}} =
             ProjectOnboard.onboard("poc-f2", opts(tmp, NoAccountUsers))

    assert gestures =~ "admin/users"
    assert gestures =~ "ghost-human"
    # nothing was created: the preflight runs BEFORE any mkdir/clone
    refute File.exists?(Path.join([tmp, "projects", "poc-f2"]))
  end

  @tag :tmp_dir
  test "account present but outside the humans team → exact admin gestures (team)", %{
    tmp_dir: tmp
  } do
    assert {:error, {:human_not_provisioned, "ghost-human", gestures}} =
             ProjectOnboard.onboard("poc-f2", opts(tmp, NoTeamUsers))

    assert gestures =~ "teams"
    assert gestures =~ "humans"
  end

  @tag :tmp_dir
  test "forge DOWN → forge_preflight_failed, NEVER creation instructions", %{
    tmp_dir: tmp
  } do
    assert {:error, {:forge_preflight_failed, {:transport, :econnrefused}}} =
             ProjectOnboard.onboard("poc-f2", opts(tmp, DownForge))
  end

  @tag :tmp_dir
  test "provisioned human → transparent preflight (the sequence continues to the next conflict)",
       %{tmp_dir: tmp} do
    o = opts(tmp, OkUsers)
    proj = Path.join([tmp, "projects", "poc-f2"])
    File.mkdir_p!(proj)

    # the preflight PASSES (otherwise we'd get human_not_provisioned); the next step
    # (refute_existing) catches the pre-existing folder → proof of order and of passage.
    assert {:error, {:already_exists, ^proj}} = ProjectOnboard.onboard("poc-f2", o)
  end

  @tag :tmp_dir
  test "DR-018: team NOT VERIFIABLE (403) → REFUSED by default (:human_team_unverifiable + gestures), nothing created",
       %{tmp_dir: tmp} do
    # DR-018: the 4th state (unverifiable) is NOT a silent :ok. A load-bearing admission that cannot
    # be proven ≠ "verified" → refused by default, with the exact admin gestures (read right /
    # prove / degraded).
    assert {:error, {:human_team_unverifiable, "ghost-human", gestures}} =
             ProjectOnboard.onboard("poc-f2", opts(tmp, ForbiddenTeamUsers))

    assert gestures =~ "NOT VERIFIABLE"
    assert gestures =~ "allow_unverifiable_human_team?"
    # an unprovable admission creates NOTHING (the guard runs BEFORE any mkdir/clone)
    refute File.exists?(Path.join([tmp, "projects", "poc-f2"]))
  end

  @tag :tmp_dir
  test "DR-018: team 403 + allow_unverifiable_human_team?: true → EXPLICIT DEGRADED MODE (proceeds, LOUD warning)",
       %{tmp_dir: tmp} do
    # Degraded mode REMAINS possible (forge where the token is not org-admin) but as a CONSCIOUS
    # opt-in mode, not an indistinguishable success: the operator sets it, the trace is LOUD,
    # create_issue remains the safety net.
    o = Keyword.put(opts(tmp, ForbiddenTeamUsers), :allow_unverifiable_human_team?, true)
    proj = Path.join([tmp, "projects", "poc-f2"])
    File.mkdir_p!(proj)

    log =
      capture_log(fn ->
        # EXPLICIT degraded: the preflight proceeds despite the 403 → the sequence continues and
        # catches the pre-existing folder (proof of passage), instead of blocking a PROVISIONED
        # human for lack of read rights.
        assert {:error, {:already_exists, ^proj}} = ProjectOnboard.onboard("poc-f2", o)
      end)

    assert log =~ "EXPLICIT DEGRADED MODE"
    assert log =~ "403"
  end

  # ── The human proves their own membership (GET /user/teams) ────────────────────────────────
  # Gitea refuses `GET /teams/<id>/members/<u>` to a plain org member (403, "Must be a team
  # member") and no token scope lifts it. Asking the HUMAN about themselves needs no privilege,
  # so the service account no longer has to sit in the team it observes.

  @tag :tmp_dir
  test "human token present → the check goes through self_team_member? with THAT token", %{
    tmp_dir: tmp
  } do
    token = Path.join(tmp, "gitea_token")
    File.write!(token, "t0k3n")

    o = Keyword.merge(opts(tmp, SelfUsers), human_token_file: token)

    # Passing the preflight is what is asserted: the sequence moves on and dies further down on
    # the forge, not on admission. A raise inside SelfUsers would surface instead.
    assert {:error, reason} = ProjectOnboard.onboard("poc-f2", o)
    refute match?({:human_not_provisioned, _, _}, reason)
    refute match?({:human_team_unverifiable, _, _}, reason)
  end

  @tag :tmp_dir
  test "human token present but the human is NOT in humans → refused, same error as before", %{
    tmp_dir: tmp
  } do
    token = Path.join(tmp, "gitea_token")
    File.write!(token, "t0k3n")

    o = Keyword.merge(opts(tmp, SelfDeniesUsers), human_token_file: token)

    assert {:error, {:human_not_provisioned, "ghost-human", gestures}} =
             ProjectOnboard.onboard("poc-f2", o)

    assert gestures =~ "humans"
  end

  @tag :tmp_dir
  test "no human token → the old path, unchanged", %{tmp_dir: tmp} do
    # `false` is what config/test.exs poses; a missing FILE must behave the same way.
    o = Keyword.merge(opts(tmp, OkUsers), human_token_file: Path.join(tmp, "absent"))

    assert {:error, reason} = ProjectOnboard.onboard("poc-f2", o)
    refute match?({:human_not_provisioned, _, _}, reason)
  end

  @tag :tmp_dir
  test "import/2 carries the SAME preflight", %{tmp_dir: tmp} do
    assert {:error, {:human_not_provisioned, "ghost-human", _}} =
             ProjectOnboard.import("fleet/poc-f2", opts(tmp, NoAccountUsers))
  end
end

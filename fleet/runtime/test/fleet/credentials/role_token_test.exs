defmodule Fleet.Credentials.RoleTokenTest do
  # async: false — mutates the global `:role_tokens_dir` config.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Fleet.Credentials.RoleToken

  setup do
    tmp = Path.join(System.tmp_dir!(), "roletoken-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    Fleet.Credentials.TestEnv.put_env_restoring(:fleet_credentials, :role_tokens_dir, tmp)

    {:ok, dir: tmp}
  end

  test "token present → returned (trimmed)", %{dir: dir} do
    File.write!(Path.join(dir, "reviewer.gitea_token"), "  tok-abc  \n")
    assert RoleToken.token("reviewer") == "tok-abc"
  end

  # F-029: a missing role token emits a Logger.warning — the degraded state must be OBSERVABLE,
  # never silent (the fail-closed policy lives in RoleIdentity; RoleToken only reports, never a
  # system fallback).
  test "F-029: absent token → nil + Logger.warning", _ctx do
    log = capture_log(fn -> assert RoleToken.token("reviewer") == nil end)
    assert log =~ "absent/unreadable"
    assert log =~ "reviewer"
    assert log =~ "unavailable"
  end

  test "F-029: empty token → nil + Logger.warning", %{dir: dir} do
    File.write!(Path.join(dir, "qualifier.gitea_token"), "   \n")
    log = capture_log(fn -> assert RoleToken.token("qualifier") == nil end)
    assert log =~ "empty"
    assert log =~ "qualifier"
  end

  test "invalid role (non path-safe) → nil (unchanged)", _ctx do
    assert RoleToken.token("../etc") == nil
  end
end

defmodule Fleet.Credentials.RoleTokenTest do
  # Serial: mutates credentials_role_tokens_dir and the shared authority double.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Fleet.Credentials.RoleToken

  setup do
    tmp = Fleet.TestEnv.tmp_path("roletoken-test")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)

    {:ok, dir: tmp}
  end

  # The authority double reads/trims fixture files; RoleToken requests the result and logs refusals.

  test "token present → returned (trimmed)", %{dir: _dir} do
    Fleet.TestEnv.put_role_token!("reviewer", "  tok-abc  \n")
    assert RoleToken.token("reviewer") == "tok-abc"
  end

  test "F-029: absent token → nil + Logger.warning nommant la cause", _ctx do
    log = capture_log(fn -> assert RoleToken.token("reviewer") == nil end)
    assert log =~ "no_role_token"
    assert log =~ "reviewer"
    assert log =~ "unavailable"
  end

  # Blank and missing files share the double's no_role_token refusal; neither yields a token.
  test "F-029: jeton VIDE → nil, jamais une chaine vide", _ctx do
    Fleet.TestEnv.put_role_token!("qualifier", "   \n")
    log = capture_log(fn -> assert RoleToken.token("qualifier") == nil end)
    assert log =~ "no_role_token"
    assert log =~ "qualifier"
  end

  test "invalid role (non path-safe) → nil (unchanged)", _ctx do
    assert RoleToken.token("../etc") == nil
  end

  describe "la cause remonte, elle ne se fond pas" do
    # Preserve the remote-outage cause so retryable failure does not look like missing provisioning.
    test "une cause distante n'est pas maquillee en jeton absent", _ctx do
      Fleet.TestEnv.put_role_token!("reviewer", "tok-abc")
      Fleet.Test.AuthorityDouble.force_fail(:forge_unreachable)
      on_exit(fn -> Fleet.Test.AuthorityDouble.force_fail(nil) end)

      log = capture_log(fn -> assert RoleToken.token("reviewer") == nil end)

      assert log =~ "forge_unreachable"
      refute log =~ "no_role_token"
    end

    # Positive control: the double must serve a token when no failure is forced.
    test "sans forcage, le meme jeton est bien servi", _ctx do
      Fleet.TestEnv.put_role_token!("reviewer", "tok-abc")
      assert RoleToken.token("reviewer") == "tok-abc"
    end
  end
end

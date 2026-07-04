defmodule Fleet.Credentials.RoleTokenTest do
  # async: false — mute la config globale `:role_tokens_dir`.
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

  test "token présent → retourné (trim)", %{dir: dir} do
    File.write!(Path.join(dir, "reviewer.gitea_token"), "  tok-abc  \n")
    assert RoleToken.token("reviewer") == "tok-abc"
  end

  # F-029 : le dégradé token-absent était SILENCIEUX (commentaire menteur « RoleToken logge »).
  # Désormais il émet un Logger.warning → le fallback token-système est OBSERVABLE.
  test "F-029 : token absent → nil + Logger.warning", _ctx do
    log = capture_log(fn -> assert RoleToken.token("reviewer") == nil end)
    assert log =~ "absent/illisible"
    assert log =~ "reviewer"
    assert log =~ "fallback token"
  end

  test "F-029 : token vide → nil + Logger.warning", %{dir: dir} do
    File.write!(Path.join(dir, "qualifier.gitea_token"), "   \n")
    log = capture_log(fn -> assert RoleToken.token("qualifier") == nil end)
    assert log =~ "vide"
    assert log =~ "qualifier"
  end

  test "rôle invalide (non path-safe) → nil (inchangé)", _ctx do
    assert RoleToken.token("../etc") == nil
  end
end

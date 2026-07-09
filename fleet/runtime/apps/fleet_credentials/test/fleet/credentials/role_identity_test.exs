defmodule Fleet.Credentials.RoleIdentityTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Fleet.Credentials.RoleIdentity

  setup do
    tmp = Path.join(System.tmp_dir!(), "roleidentity-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Fleet.Credentials.TestEnv.put_env_restoring(:fleet_credentials, :role_tokens_dir, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, dir: tmp}
  end

  test "token présent → {:ok, %RoleIdentity{}} avec le token vérifié", %{dir: dir} do
    File.write!(Path.join(dir, "gatekeeper.gitea_token"), "  tok-gk  \n")

    assert {:ok, %RoleIdentity{role: "gatekeeper", token: "tok-gk"}} =
             RoleIdentity.for_role("gatekeeper")
  end

  test "token ABSENT → {:error, :role_token_unavailable} (JAMAIS un fallback système)" do
    assert {:error, :role_token_unavailable} = RoleIdentity.for_role("gatekeeper")
  end

  test "token VIDE → {:error} (fail-closed)", %{dir: dir} do
    File.write!(Path.join(dir, "reviewer.gitea_token"), "   \n")

    assert capture_log(fn ->
             assert {:error, :role_token_unavailable} = RoleIdentity.for_role("reviewer")
           end) =~ "empty"
  end

  test "rôle non-path-safe / vide / nil → {:error}" do
    assert {:error, :role_token_unavailable} = RoleIdentity.for_role("../etc")
    assert {:error, :role_token_unavailable} = RoleIdentity.for_role("")
    assert {:error, :role_token_unavailable} = RoleIdentity.for_role(nil)
  end
end

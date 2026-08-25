defmodule Fleet.Credentials.RoleIdentityTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Fleet.Credentials.RoleIdentity

  setup do
    tmp = Fleet.TestEnv.tmp_path("roleidentity-test")
    File.mkdir_p!(tmp)
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, dir: tmp}
  end

  test "token present → {:ok, %RoleIdentity{}} with the verified token", %{dir: dir} do
    Fleet.TestEnv.put_role_token!("gatekeeper", "  tok-gk  \n")

    assert {:ok, %RoleIdentity{role: "gatekeeper", token: "tok-gk"}} =
             RoleIdentity.for_role("gatekeeper")
  end

  test "token ABSENT → {:error, :role_token_unavailable} (NEVER a system fallback)" do
    assert {:error, :role_token_unavailable} = RoleIdentity.for_role("gatekeeper")
  end

  # ⚠ « empty » A DISPARU DE L'ASSERTION PARCE QUE CE PROCESS NE LIT PLUS LE FICHIER. Le jeton se
  # demande au service d'autorite, qui rend `no_role_token` pour un fichier vide comme pour un
  # fichier absent — meme remede, meme effet. Ce que ce temoin garde est le point qui n'a jamais
  # bouge et qui est le seul a compter ici : un jeton vide ne devient JAMAIS une identite. Pas de
  # `%RoleIdentity{token: ""}`, pas de repli sur le compte systeme.
  test "EMPTY token → {:error} (fail-closed)", %{dir: _dir} do
    Fleet.TestEnv.put_role_token!("reviewer", "   \n")

    assert capture_log(fn ->
             assert {:error, :role_token_unavailable} = RoleIdentity.for_role("reviewer")
           end) =~ "no_role_token"
  end

  test "non-path-safe / empty / nil role → {:error}" do
    assert {:error, :role_token_unavailable} = RoleIdentity.for_role("../etc")
    assert {:error, :role_token_unavailable} = RoleIdentity.for_role("")
    assert {:error, :role_token_unavailable} = RoleIdentity.for_role(nil)
  end

  # THE SECOND HALF OF THE IDENTITY. This module answered the token and nothing answered the
  # ACCOUNT, so the runtime addressed forge accounts by the bare role name while provisioning had
  # created them as `<tier>_<role>`: `request_review` 404'd and deliverable PRs got no judge.
  describe "login/1 + role_of_login/1 — the account a role writes under" do
    test "the prefix follows the TIER, not the file that wins the overlay" do
      # `architect` is a SYSTEM authority — the same one in every org — so its account stays
      # `system_architect` even though a business catalogue may ship its own `architect.yaml` to
      # widen its tools. A business role takes the catalogue's own name.
      assert {:ok, "system_architect"} = RoleIdentity.login("architect")
      assert {:ok, "fleet_qualifier"} = RoleIdentity.login("qualifier")
    end

    test "the inverse round-trips, and is case-insensitive like Gitea itself" do
      assert {:ok, "qualifier"} = RoleIdentity.role_of_login("fleet_qualifier")
      assert {:ok, "qualifier"} = RoleIdentity.role_of_login("Fleet_Qualifier")
      assert {:ok, "architect"} = RoleIdentity.role_of_login("system_architect")
    end

    test "a role outside the roster fails LOUD in both directions" do
      assert {:error, {:role_not_in_roster, "ghost-role"}} = RoleIdentity.login("ghost-role")
      assert {:error, {:login_not_a_role, "lordzurp"}} = RoleIdentity.role_of_login("lordzurp")
    end

    test "role_or_login/1 leaves a HUMAN verbatim — F-C061 must keep seeing them as foreign" do
      # Coercing an unknown login into a role would slip a stranger into the jury, where they can
      # skew or block a verdict. Translate what is ours, leave the rest exactly as it came.
      assert "qualifier" = RoleIdentity.role_or_login("fleet_qualifier")
      assert "lordzurp" = RoleIdentity.role_or_login("lordzurp")
      assert "dependabot[bot]" = RoleIdentity.role_or_login("dependabot[bot]")
    end
  end
end

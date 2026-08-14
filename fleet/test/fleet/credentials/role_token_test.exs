defmodule Fleet.Credentials.RoleTokenTest do
  # async: false — mutates the global `:role_tokens_dir` config.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Fleet.Credentials.RoleToken

  setup do
    tmp = Path.join(System.tmp_dir!(), "roletoken-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)

    {:ok, dir: tmp}
  end

  test "token present → returned (trimmed)", %{dir: dir} do
    Fleet.TestEnv.put_role_token!("reviewer", "  tok-abc  \n")
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
    Fleet.TestEnv.put_role_token!("qualifier", "   \n")
    log = capture_log(fn -> assert RoleToken.token("qualifier") == nil end)
    assert log =~ "empty"
    assert log =~ "qualifier"
  end

  test "invalid role (non path-safe) → nil (unchanged)", _ctx do
    assert RoleToken.token("../etc") == nil
  end

  # 6-030 — LE DIAGNOSTIC NOMMAIT UN FICHIER QUAND LA CAUSE ETAIT LE REPERTOIRE. Un deploiement dont
  # `FORGE_ROLE_TOKENS_DIR` pointe a cote — ou dont le provisionnement n'a pas tourne — rendait UNE
  # ligne PAR ROLE, chacune exacte (« ce jeton-la est absent ») et aucune ne disant la seule chose
  # qui oriente : aucun role ne peut signer, et ce n'est pas un probleme de role.
  describe "6-030 — le repertoire absent se nomme lui-meme, une fois par role" do
    test "repertoire absent → la ligne nomme le REPERTOIRE et l'action", %{dir: dir} do
      File.rm_rf!(dir)

      log = capture_log(fn -> assert RoleToken.token("reviewer") == nil end)

      assert log =~ "the tokens DIRECTORY #{dir} is itself absent"
      assert log =~ "NO role can sign"
      assert log =~ "FORGE_ROLE_TOKENS_DIR"
      # La ligne par-role reste : on AJOUTE la cause, on ne remplace pas le constat.
      assert log =~ "absent/unreadable"
      assert log =~ "reviewer"
    end

    # TEMOIN — sans lui, un indice inconditionnel passerait le test ci-dessus et accuserait le
    # repertoire a chaque jeton manquant d'un repertoire parfaitement sain.
    test "repertoire present, jeton absent → la ligne NE nomme PAS le repertoire", %{dir: dir} do
      assert File.dir?(dir)

      log = capture_log(fn -> assert RoleToken.token("reviewer") == nil end)

      assert log =~ "absent/unreadable"
      refute log =~ "is itself absent"
      refute log =~ "NO role can sign"
    end
  end
end

defmodule Fleet.Credentials.ForgeAuthTest do
  # async: false — mute `:fleet_credentials, :forge_auth` (env applicatif global).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fleet.Credentials.ForgeAuth
  alias Fleet.Credentials.TestEnv

  setup do
    # Les tests posent/effacent :forge_auth eux-mêmes ; on ne capture ici que la restauration.
    TestEnv.restore_env_on_exit(:fleet_credentials, :forge_auth)
    :ok
  end

  describe "git_env/0" do
    # MOVE-1/MA-22 — `GIT_TERMINAL_PROMPT=0` est désormais posé d'OFFICE (inconditionnel) : le contrat
    # de `git_env/0` n'est plus « [] si non configuré » mais « TOUJOURS la borne anti-prompt, + l'auth
    # forge si configurée ». L'invariant ne dépend pas du forge_auth (le repo local sans token est
    # justement le cas qui prompterait).
    test "non configuré → seule la borne anti-prompt (GIT_TERMINAL_PROMPT=0)" do
      Application.delete_env(:fleet_credentials, :forge_auth)
      assert [{"GIT_TERMINAL_PROMPT", "0"}] = ForgeAuth.git_env()
    end

    test "MINE-CRED-01 : config PRÉSENTE mais incomplète (token vide / prefix manquant) → anti-prompt seul + LOUD" do
      # Avant : swallow silencieux (`_ ->`). Une config de credential cassée doit être LOUD (sinon git part
      # non-authentifié et n'échoue qu'au remote 403/404, masquant la vraie cause).
      log1 =
        capture_log(fn ->
          Application.put_env(:fleet_credentials, :forge_auth, %{
            url_prefix: "https://f/",
            token: ""
          })

          assert [{"GIT_TERMINAL_PROMPT", "0"}] = ForgeAuth.git_env()
        end)

      assert log1 =~ "PRESENT but malformed"

      log2 =
        capture_log(fn ->
          Application.put_env(:fleet_credentials, :forge_auth, %{token: "t"})
          assert [{"GIT_TERMINAL_PROMPT", "0"}] = ForgeAuth.git_env()
        end)

      assert log2 =~ "PRESENT but malformed"
    end

    test "R1-15 : url_prefix avec newline/control → header SKIP + LOUD (pas d'injection de clé git-config)" do
      log =
        capture_log(fn ->
          Application.put_env(:fleet_credentials, :forge_auth, %{
            url_prefix: "https://f/\ninject",
            token: "t"
          })

          assert [{"GIT_TERMINAL_PROMPT", "0"}] = ForgeAuth.git_env()
        end)

      assert log =~ "control char"
    end

    test "configuré → GIT_TERMINAL_PROMPT=0 + GIT_CONFIG_* (token DANS l'env, jamais sur l'argv — F087)" do
      Application.put_env(:fleet_credentials, :forge_auth, %{
        url_prefix: "https://forge.example/",
        token: "SECRET123"
      })

      assert [
               {"GIT_TERMINAL_PROMPT", "0"},
               {"GIT_CONFIG_COUNT", "1"},
               {"GIT_CONFIG_KEY_0", "http.https://forge.example/.extraheader"},
               {"GIT_CONFIG_VALUE_0", "Authorization: token SECRET123"}
             ] = ForgeAuth.git_env()
    end
  end

  describe "preuve locale : git honore git_env (mécanisme F087, sans forge)" do
    test "git config --get lit l'extraheader depuis l'env, pas l'argv" do
      Application.put_env(:fleet_credentials, :forge_auth, %{
        url_prefix: "https://forge.example/",
        token: "SECRET123"
      })

      # `git config --get` ne reçoit AUCUN -c sur l'argv ; s'il rend le header, c'est qu'il l'a lu
      # depuis GIT_CONFIG_* (env). C'est exactement le canal qu'utilisent clone/fetch/ls-remote/push.
      {out, 0} =
        System.cmd("git", ["config", "--get", "http.https://forge.example/.extraheader"],
          env: ForgeAuth.git_env(),
          stderr_to_stdout: true
        )

      assert String.trim(out) == "Authorization: token SECRET123"
    end
  end
end

defmodule Fleet.Credentials.ForgeAuthTest do
  # async: false — mutates `:lcars_fleet, :credentials_forge_auth` (global application env).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fleet.Credentials.ForgeAuth
  alias Fleet.TestEnv

  setup do
    # Tests set/delete :forge_auth themselves; here we only capture the restoration.
    TestEnv.restore_env_on_exit(:lcars_fleet, :credentials_forge_auth)
    :ok
  end

  describe "git_env/0" do
    # MOVE-1/MA-22 — `GIT_TERMINAL_PROMPT=0` is set UNCONDITIONALLY: the contract of `git_env/0`
    # is not "[] when unconfigured" but "ALWAYS the anti-prompt bound, plus the forge auth when
    # configured". The invariant does not depend on forge_auth (a local repo without a token is
    # precisely the case that would prompt).
    test "unconfigured → anti-prompt bound only (GIT_TERMINAL_PROMPT=0)" do
      Application.delete_env(:lcars_fleet, :credentials_forge_auth)
      assert [{"GIT_TERMINAL_PROMPT", "0"}] = ForgeAuth.git_env()
    end

    test "MINE-CRED-01: config PRESENT but incomplete (empty token / missing prefix) → anti-prompt only + LOUD" do
      # A broken credential config must be LOUD, never silently swallowed (otherwise git goes out
      # unauthenticated and only fails at the remote with 403/404, masking the real cause).
      log1 =
        capture_log(fn ->
          Application.put_env(:lcars_fleet, :credentials_forge_auth, %{
            url_prefix: "https://f/",
            token: ""
          })

          assert [{"GIT_TERMINAL_PROMPT", "0"}] = ForgeAuth.git_env()
        end)

      assert log1 =~ "PRESENT but malformed"

      log2 =
        capture_log(fn ->
          Application.put_env(:lcars_fleet, :credentials_forge_auth, %{token: "t"})
          assert [{"GIT_TERMINAL_PROMPT", "0"}] = ForgeAuth.git_env()
        end)

      assert log2 =~ "PRESENT but malformed"
    end

    test "R1-15: url_prefix with newline/control → header SKIPPED + LOUD (no git-config key injection)" do
      log =
        capture_log(fn ->
          Application.put_env(:lcars_fleet, :credentials_forge_auth, %{
            url_prefix: "https://f/\ninject",
            token: "t"
          })

          assert [{"GIT_TERMINAL_PROMPT", "0"}] = ForgeAuth.git_env()
        end)

      assert log =~ "control char"
    end

    test "configured → GIT_TERMINAL_PROMPT=0 + GIT_CONFIG_* (token IN the env, never on the argv — F087)" do
      Application.put_env(:lcars_fleet, :credentials_forge_auth, %{
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

  describe "git_env_result/0 (auth-required paths, fail-loud on malformed — DR-024)" do
    test "absent (nil) → {:ok, anti-prompt only} (the legit no-auth state)" do
      Application.delete_env(:lcars_fleet, :credentials_forge_auth)
      assert {:ok, [{"GIT_TERMINAL_PROMPT", "0"}]} = ForgeAuth.git_env_result()
    end

    test "PRESENT but malformed (empty token) → {:error, :forge_auth_malformed} (never a silent no-auth env)" do
      capture_log(fn ->
        Application.put_env(:lcars_fleet, :credentials_forge_auth, %{
          url_prefix: "https://f/",
          token: ""
        })

        assert {:error, :forge_auth_malformed} = ForgeAuth.git_env_result()
      end)
    end

    test "url_prefix with a control char → {:error, :forge_auth_malformed}" do
      capture_log(fn ->
        Application.put_env(:lcars_fleet, :credentials_forge_auth, %{
          url_prefix: "https://f/\ninject",
          token: "t"
        })

        assert {:error, :forge_auth_malformed} = ForgeAuth.git_env_result()
      end)
    end

    test "valid → {:ok, [anti-prompt + auth extraheader]}" do
      Application.put_env(:lcars_fleet, :credentials_forge_auth, %{
        url_prefix: "https://forge.example/",
        token: "SECRET123"
      })

      assert {:ok, [{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_CONFIG_COUNT", "1"} | _]} =
               ForgeAuth.git_env_result()
    end
  end

  describe "local proof: git honors git_env (F087 mechanism, no forge)" do
    test "git config --get reads the extraheader from the env, not the argv" do
      Application.put_env(:lcars_fleet, :credentials_forge_auth, %{
        url_prefix: "https://forge.example/",
        token: "SECRET123"
      })

      # `git config --get` receives NO -c on the argv; if it returns the header, it read it from
      # GIT_CONFIG_* (env). This is exactly the channel clone/fetch/ls-remote/push use.
      {out, 0} =
        System.cmd("git", ["config", "--get", "http.https://forge.example/.extraheader"],
          env: ForgeAuth.git_env(),
          stderr_to_stdout: true
        )

      assert String.trim(out) == "Authorization: token SECRET123"
    end
  end
end

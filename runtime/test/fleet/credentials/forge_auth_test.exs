defmodule Fleet.Credentials.ForgeAuthTest do
  # async: false — mutates `:lcars_fleet, :credentials_forge_auth` (global application env).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fleet.Credentials.ForgeAuth
  alias Fleet.TestEnv

  # Config names the account; the authority test double reads its token from the fixture directory.
  @account "system_pusher"
  @token "SECRET123"

  setup do
    # Individual tests set/delete auth config; register restoration before they run.
    TestEnv.restore_env_on_exit(:lcars_fleet, :credentials_forge_auth)

    tmp = TestEnv.tmp_path("forgeauth-test")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)
    File.write!(Path.join(tmp, "#{@account}.gitea_token"), @token)

    :ok
  end

  defp configure(prefix, account \\ @account) do
    Application.put_env(:lcars_fleet, :credentials_forge_auth, %{
      url_prefix: prefix,
      account: account
    })
  end

  describe "git_env/0" do
    test "unconfigured → anti-prompt bound only (GIT_TERMINAL_PROMPT=0)" do
      Application.delete_env(:lcars_fleet, :credentials_forge_auth)
      assert [{"GIT_TERMINAL_PROMPT", "0"}] = ForgeAuth.git_env()
    end

    test "MINE-CRED-01: config PRESENT but incomplete (empty account / missing prefix) → anti-prompt only + LOUD" do
      log1 =
        capture_log(fn ->
          configure("https://f/", "")
          assert [{"GIT_TERMINAL_PROMPT", "0"}] = ForgeAuth.git_env()
        end)

      assert log1 =~ "PRESENT but malformed"

      log2 =
        capture_log(fn ->
          Application.put_env(:lcars_fleet, :credentials_forge_auth, %{account: @account})
          assert [{"GIT_TERMINAL_PROMPT", "0"}] = ForgeAuth.git_env()
        end)

      assert log2 =~ "PRESENT but malformed"
    end

    test "R1-15: url_prefix with newline/control → header SKIPPED + LOUD (no git-config key injection)" do
      log =
        capture_log(fn ->
          configure("https://f/\ninject")
          assert [{"GIT_TERMINAL_PROMPT", "0"}] = ForgeAuth.git_env()
        end)

      assert log =~ "control char"
    end

    test "configured → GIT_TERMINAL_PROMPT=0 + GIT_CONFIG_* (token IN the env, never on the argv — F087)" do
      configure("https://forge.example/")

      assert [
               {"GIT_TERMINAL_PROMPT", "0"},
               {"GIT_CONFIG_COUNT", "1"},
               {"GIT_CONFIG_KEY_0", "http.https://forge.example/.extraheader"},
               {"GIT_CONFIG_VALUE_0", "Authorization: token SECRET123"}
             ] = ForgeAuth.git_env()
    end

    # Same env fallback, different diagnosis: valid account configuration but no issued token.
    test "compte configure, jeton indisponible → anti-prompt seul + LOUD (jamais un push muet)" do
      configure("https://forge.example/", "compte_sans_jeton")

      log = capture_log(fn -> assert [{"GIT_TERMINAL_PROMPT", "0"}] = ForgeAuth.git_env() end)

      assert log =~ "aucun jeton pour le compte"
      refute log =~ "PRESENT but malformed"
    end
  end

  describe "account/0 — la source unique du compte du conteneur" do
    test "configure → le nom du compte" do
      configure("https://forge.example/")
      assert ForgeAuth.account() == @account
    end

    test "absent → nil, jamais un nom devine" do
      Application.delete_env(:lcars_fleet, :credentials_forge_auth)
      assert ForgeAuth.account() == nil
    end

    test "config presente mais sans compte → nil" do
      Application.put_env(:lcars_fleet, :credentials_forge_auth, %{url_prefix: "https://f/"})
      assert ForgeAuth.account() == nil
    end
  end

  describe "git_env_result/0 (auth-required paths, fail-loud on malformed — DR-024)" do
    test "absent (nil) → {:ok, anti-prompt only} (the legit no-auth state)" do
      Application.delete_env(:lcars_fleet, :credentials_forge_auth)
      assert {:ok, [{"GIT_TERMINAL_PROMPT", "0"}]} = ForgeAuth.git_env_result()
    end

    test "PRESENT but malformed (empty account) → {:error, :forge_auth_malformed} (never a silent no-auth env)" do
      capture_log(fn ->
        configure("https://f/", "")
        assert {:error, :forge_auth_malformed} = ForgeAuth.git_env_result()
      end)
    end

    test "url_prefix with a control char → {:error, :forge_auth_malformed}" do
      capture_log(fn ->
        configure("https://f/\ninject")
        assert {:error, :forge_auth_malformed} = ForgeAuth.git_env_result()
      end)
    end

    # Separate configuration repair from authority/token availability diagnosis.
    test "compte configure, jeton indisponible → {:error, :forge_auth_unavailable}, PAS malformed" do
      capture_log(fn ->
        configure("https://forge.example/", "compte_sans_jeton")
        assert {:error, :forge_auth_unavailable} = ForgeAuth.git_env_result()
      end)
    end

    test "valid → {:ok, [anti-prompt + auth extraheader]}" do
      configure("https://forge.example/")

      assert {:ok, [{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_CONFIG_COUNT", "1"} | _]} =
               ForgeAuth.git_env_result()
    end
  end

  describe "local proof: git honors git_env (F087 mechanism, no forge)" do
    test "git config --get reads the extraheader from the env, not the argv" do
      configure("https://forge.example/")

      # Exercise the actual Git config reader with env only; this is not a remote-auth test.
      {out, 0} =
        System.cmd("git", ["config", "--get", "http.https://forge.example/.extraheader"],
          env: ForgeAuth.git_env(),
          stderr_to_stdout: true
        )

      assert String.trim(out) == "Authorization: token SECRET123"
    end
  end
end

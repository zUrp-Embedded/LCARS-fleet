defmodule Fleet.Credentials.ForgeAuthTest do
  # async: false — mutates `:lcars_fleet, :credentials_forge_auth` (global application env).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fleet.Credentials.ForgeAuth
  alias Fleet.TestEnv

  # ⚠ LA CONFIG NE PORTE PLUS LE JETON, SEULEMENT LE COMPTE — et c'est la totalite de ce que ces
  # temoins ont eu a changer. `%{url_prefix:, token:}` est devenu `%{url_prefix:, account:}`, le
  # jeton se demandant au service d'autorite AU MOMENT DE POUSSER.
  #
  # Ce qu'ils continuent d'epingler est inchange, et c'est le point : le jeton sort dans
  # `GIT_CONFIG_*`, jamais sur l'argv ; `GIT_TERMINAL_PROMPT=0` est inconditionnel ; un prefixe qui
  # porte un saut de ligne est refuse au lieu d'injecter une cle de git-config.
  @account "system_pusher"
  @token "SECRET123"

  setup do
    # Tests set/delete :forge_auth themselves; here we only capture the restoration.
    TestEnv.restore_env_on_exit(:lcars_fleet, :credentials_forge_auth)

    tmp = Fleet.TestEnv.tmp_path("forgeauth-test")
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
    # MOVE-1/MA-22 — `GIT_TERMINAL_PROMPT=0` is set UNCONDITIONALLY: the contract of `git_env/0`
    # is not "[] when unconfigured" but "ALWAYS the anti-prompt bound, plus the forge auth when
    # configured". The invariant does not depend on forge_auth (a local repo without a token is
    # precisely the case that would prompt).
    test "unconfigured → anti-prompt bound only (GIT_TERMINAL_PROMPT=0)" do
      Application.delete_env(:lcars_fleet, :credentials_forge_auth)
      assert [{"GIT_TERMINAL_PROMPT", "0"}] = ForgeAuth.git_env()
    end

    test "MINE-CRED-01: config PRESENT but incomplete (empty account / missing prefix) → anti-prompt only + LOUD" do
      # A broken credential config must be LOUD, never silently swallowed (otherwise git goes out
      # unauthenticated and only fails at the remote with 403/404, masking the real cause).
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

    # ⚠ LE TEMOIN DE LA NOUVELLE CAUSE, ET IL EST STRUCTUREL. Un compte CONFIGURE dont le service ne
    # rend pas le jeton n'est PAS la meme chose qu'une boite sans config : la premiere croit pouvoir
    # pousser et ne le peut pas. `git_env/0` degrade pareil dans les deux cas — c'est le bon repli,
    # git echoue bruyamment — mais le journal doit dire laquelle des deux, sinon l'operateur cherche
    # une config cassee alors qu'il lui manque une unite qui tourne.
    test "compte configure, jeton indisponible → anti-prompt seul + LOUD (jamais un push muet)" do
      configure("https://forge.example/", "compte_sans_jeton")

      log = capture_log(fn -> assert [{"GIT_TERMINAL_PROMPT", "0"}] = ForgeAuth.git_env() end)

      assert log =~ "aucun jeton pour le compte"
      refute log =~ "PRESENT but malformed"
    end
  end

  describe "account/0 — la source unique du compte de la boite" do
    test "configure → le nom du compte" do
      configure("https://forge.example/")
      assert ForgeAuth.account() == @account
    end

    # `nil` EST UN ETAT LEGITIME, PAS UNE PANNE : une boite en mode outil, un banc sans forge. Ce
    # module ne devine aucun nom par defaut — devine-le ici, et deux endroits sauraient « le compte
    # du systeme », dont un se tromperait en silence sur toute boite qui ne s'appelle pas comme la
    # boite de reference.
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

    # ⚠ LES DEUX REFUS NE SE CONFONDENT PAS, ET LEURS REMEDES SONT OPPOSES : `malformed` se corrige
    # dans la config de la boite, `unavailable` demande si le service d'autorite repond. Les fondre
    # enverrait la moitie des pannes au mauvais geste — c'est exactement la separation que DR-024 a
    # posee entre « absent » et « malforme », etendue au troisieme etat que ce chantier introduit.
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

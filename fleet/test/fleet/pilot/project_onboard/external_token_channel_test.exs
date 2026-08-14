defmodule Fleet.Project.OnboardExternalTokenChannelTest do
  use ExUnit.Case, async: false

  alias Fleet.Project.Onboard

  @moduledoc """
  JG-082 — le credential d'import d'un depot externe voyage par l'ENV, jamais par l'argv.

  Il etait injecte en USERINFO D'URL (`https://oauth2:<token>@host/…`) puis pose en argv de
  `git clone` : lisible par tout compte local dans `ps` pendant toute la duree du clone (jusqu'a
  120 s), et ressorti dans les messages d'erreur de git, qui citent l'URL distante — sortie qui
  remonte au pod appelant sans redaction.

  ⚠ Le Constat de la fiche, pris a la lettre, est FAUX : le pod ne recoit jamais
  `LCARS_EXTERNAL_GIT_TOKEN` (lu dans l'env du demon, clone dans un scratch cote BEAM, hors de tout
  sandbox). Ce qui est reel est le canal, et il l'etait deja avant l'audit.
  """

  @var "LCARS_EXTERNAL_GIT_TOKEN"

  setup do
    before = System.get_env(@var)

    on_exit(fn ->
      if before, do: System.put_env(@var, before), else: System.delete_env(@var)
    end)

    :ok
  end

  test "le token part en en-tete HTTP dans l'ENV, borne a l'hote du clone" do
    System.put_env(@var, "sekret-token-42")

    assert {:ok, env} = Onboard.external_auth_env("https://github.example/org/repo.git")

    assert {"GIT_CONFIG_KEY_0", "http.https://github.example/.extraheader"} in env,
           "l'en-tete doit etre borne a `scheme://host/` — sinon il part vers l'hote d'une redirection"

    expected = "Authorization: Basic " <> Base.encode64("oauth2:sekret-token-42")

    assert {"GIT_CONFIG_VALUE_0", expected} in env,
           "le schema d'authentification ne change pas (ce que l'userinfo transmettait), seul le canal change"
  end

  test "sans token, l'env est celui du systeme — aucun en-tete pose" do
    System.delete_env(@var)

    assert {:ok, env} = Onboard.external_auth_env("https://github.example/org/repo.git")
    refute Enum.any?(env, &match?({"GIT_CONFIG_KEY_0", _}, &1))
  end

  test "un caractere de controle dans l'autorite est REFUSE — sinon une cle git-config est injectee" do
    System.put_env(@var, "sekret-token-42")

    assert {:error, {:external_clone_failed, :url_malformed}} =
             Onboard.external_auth_env("https://evil\nhost/org/repo.git")
  end

  # Le port non standard fait partie du prefixe : deux services sur un meme hote ne partagent pas un
  # credential.
  test "un port non standard entre dans le prefixe" do
    System.put_env(@var, "t")

    assert {:ok, env} = Onboard.external_auth_env("https://forge.example:8443/o/r.git")
    assert {"GIT_CONFIG_KEY_0", "http.https://forge.example:8443/.extraheader"} in env
  end
end

defmodule Fleet.Forge.Client.BotLoginCacheTest do
  use ExUnit.Case, async: false

  alias Fleet.Forge.Client, as: ForgeClient
  alias Fleet.Forge.Client.Transport

  # A stale login changes which comment authors F059 trusts. The cache has one slot per URL,
  # with token digest and login in the value; raw tokens are not stored there.

  defmodule Whoami do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(login), do: login

    @impl Plug
    # Les routes de listes doivent rendre une liste pour exercer aussi le chemin public.
    def call(conn, login) do
      body =
        if String.ends_with?(conn.request_path, "/user"),
          do: %{"login" => login},
          else: []

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.send_resp(200, JSON.encode!(body))
    end
  end

  # The plug's login changes alongside the token; it does not inspect the Authorization header.
  defp comments_for(login) do
    [
      base_url: "http://fake.test",
      req_options: [plug: {Whoami, login}]
    ]
  end

  test "two tokens on the same forge do not share one cached login" do
    a =
      comments_for("system_starfleet") ++ [token: "token-A-#{System.unique_integer([:positive])}"]

    b = comments_for("lcars-other") ++ [token: "token-B-#{System.unique_integer([:positive])}"]

    assert {:ok, la} = resolve(a)
    assert {:ok, lb} = resolve(b)

    assert la == "system_starfleet"
    assert lb == "lcars-other", "the second token inherited the first one's cached login"
  end

  test "the same token resolves once and is reused" do
    # Equal replies alone do not prove a cache hit: request counts are not asserted.
    tok = "token-same-#{System.unique_integer([:positive])}"
    opts = comments_for("system_starfleet") ++ [token: tok]

    assert {:ok, "system_starfleet"} = resolve(opts)
    assert {:ok, "system_starfleet"} = resolve(opts)
  end

  defp resolve(opts) do
    Transport.forge_bot_login(
      %{
        base_url: Keyword.fetch!(opts, :base_url),
        token: Keyword.fetch!(opts, :token),
        anonymous: false,
        req_options: Keyword.get(opts, :req_options, [])
      },
      []
    )
  end

  test "the client's public path still works with an explicit login (no resolution at all)" do
    # Exercises the public path, but the empty list does not prove /user was never called.
    assert {:ok, _} =
             ForgeClient.count_signed_step_runs(
               "fleet/p",
               1,
               base_url: "http://fake.test",
               token: "t",
               forge_bot_login: "system_starfleet",
               req_options: [plug: {Whoami, "ignored"}]
             )
  end

  # JG-066 : garder l'empreinte dans la valeur evite une entree par rotation.
  test "JG-066 : N rotations de jeton ne font pas croitre le cache lineairement en N" do
    # Compter toute arite detecte aussi l'ancienne cle a quatre elements ; un filtre sur
    # la nouvelle forme comptait zero sous mutation. login_of exerce directement le cache.
    base = fn ->
      Enum.count(:persistent_term.get(), fn {k, _} ->
        is_tuple(k) and tuple_size(k) >= 2 and elem(k, 1) == :bot_login
      end)
    end

    before = base.()

    for i <- 1..8 do
      expected = "login-#{i}"

      assert {:ok, ^expected} =
               Transport.login_of(config_from(comments_for(expected) ++ [token: "rot-#{i}"]))
    end

    grown = base.() - before

    assert grown <= 1,
           "le cache a gagne #{grown} entrees pour 8 rotations — l'empreinte du jeton est " <>
             "redevenue une CLE au lieu d'une VALEUR"
  end

  test "TEMOIN JG-066 : apres rotation, c'est le NOUVEAU login qui est servi (pas le cache perime)" do
    opts_a = comments_for("bot-a") ++ [token: "tok-a"]
    opts_b = comments_for("bot-b") ++ [token: "tok-b"]

    assert {:ok, "bot-a"} = Transport.login_of(config_from(opts_a))
    assert {:ok, "bot-b"} = Transport.login_of(config_from(opts_b))
    assert {:ok, "bot-a"} = Transport.login_of(config_from(opts_a))
  end

  defp config_from(opts) do
    {:ok, config} = Transport.resolve_config(opts)
    config
  end

  # JG-089 : diagnostic du 429, sans reprise automatique. Le delai vient du champ JSON
  # retry_after ; ces fixtures ne servent aucun en-tete HTTP Retry-After.
  describe "JG-089 — le 429 est nomme TRANSITOIRE, symetrique de 412/423" do
    defmodule TooMany do
      @moduledoc false
      @behaviour Plug
      @impl Plug
      def init(body), do: body
      @impl Plug
      def call(conn, body) do
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(429, JSON.encode!(body))
      end
    end

    defp call_429(body) do
      opts = [base_url: "http://fake.test", token: "t", req_options: [plug: {TooMany, body}]]

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:http, 429, _}} =
                 Transport.http_get(config_from(opts), "/user")
      end)
    end

    test "429 avec Retry-After annonce → journalise TRANSITOIRE et le delai" do
      log = call_429(%{"retry_after" => 30, "message" => "slow down"})

      assert log =~ "TRANSITOIRE"
      assert log =~ "reessai dans 30 s"
      refute log =~ "PERMANENTE", "le 429 a ete classe comme definitif"
    end

    test "429 SANS Retry-After → transitoire quand meme, delai dit non annonce" do
      log = call_429(%{"message" => "slow down"})

      assert log =~ "TRANSITOIRE"
      assert log =~ "delai non annonce"
    end

    test "TEMOIN — 423 reste PERMANENT (le symetrique n'a pas efface son jumeau)" do
      defmodule Locked do
        @moduledoc false
        @behaviour Plug
        @impl Plug
        def init(o), do: o
        @impl Plug
        def call(conn, _) do
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(423, JSON.encode!(%{"message" => "locked"}))
        end
      end

      opts = [base_url: "http://fake.test", token: "t", req_options: [plug: {Locked, []}]]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:http, 423, _}} =
                   Transport.http_get(config_from(opts), "/user")
        end)

      assert log =~ "PERMANENTE"
    end
  end
end

defmodule Fleet.Pilot.ForgeBotLoginCacheTest do
  use ExUnit.Case, async: false

  alias Fleet.Forge.Client, as: ForgeClient
  alias Fleet.Forge.Client.Transport

  # THE BOT LOGIN IS A PROPERTY OF THE TOKEN, NOT OF THE MODULE.
  #
  # It was cached in `:persistent_term` under `{Transport, :bot_login}` — one slot for the whole
  # node. A second token (a rotation, or two forges reached from the same VM) therefore inherited
  # the first one's login for the lifetime of the node. That login is the argument of
  # `ForgeProtocol.system_authored?/2`, the trust primitive: getting it wrong is not a cosmetic
  # slip, it compares a comment's author against the WRONG account — the filter that F059 exists to
  # enforce would then trust, or reject, the wrong writer.
  #
  # The key now carries what determines the answer. The token itself is never stored: persistent_term
  # is readable by every process on the node, so only a digest goes in.

  defmodule Whoami do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(login), do: login

    @impl Plug
    # Route par chemin : `/user` rend l'identite, tout le reste rend une liste vide. Un plug qui
    # repondrait l'identite a TOUTES les routes ferait echouer les appels de liste sur
    # `:unexpected_page_shape` — le test mesurerait alors sa propre negligence.
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

  # `/user` answers whatever the plug was built with, so a differing answer can only come from a
  # differing token — which is exactly the axis under test.
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

    # `count_signed_step_runs/3` is the shortest public path that resolves the bot login, and its
    # filter is where a wrong login does damage. The plug answers /user for both calls.
    assert {:ok, la} = resolve(a)
    assert {:ok, lb} = resolve(b)

    assert la == "system_starfleet"
    assert lb == "lcars-other", "the second token inherited the first one's cached login"
  end

  test "the same token resolves once and is reused" do
    tok = "token-same-#{System.unique_integer([:positive])}"
    opts = comments_for("system_starfleet") ++ [token: tok]

    assert {:ok, "system_starfleet"} = resolve(opts)
    assert {:ok, "system_starfleet"} = resolve(opts)
  end

  defp resolve(opts) do
    # No public accessor for the login; the transport exposes it to the client, so we go through the
    # documented seam rather than reaching into persistent_term (which would test the cache, not the
    # behaviour that depends on it).
    apply(Fleet.Forge.Client.Transport, :forge_bot_login, [
      %{
        base_url: Keyword.fetch!(opts, :base_url),
        token: Keyword.fetch!(opts, :token),
        req_options: Keyword.get(opts, :req_options, [])
      },
      []
    ])
  end

  test "the client's public path still works with an explicit login (no resolution at all)" do
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

  # JG-066 — L'EMPREINTE DU JETON ETAIT DANS LA CLE, DONC CHAQUE ROTATION AJOUTAIT UNE ENTREE.
  # L'ancienne n'etait jamais rendue : sur un noeud de longue duree, le nombre d'entrees
  # `:persistent_term` croissait lineairement avec le nombre de jetons successifs, et chaque `put`
  # declenche un GC global. Elle est desormais dans la VALEUR : une rotation ECRASE au lieu
  # d'ajouter, et la propriete de correction (un login memorise pour un jeton n'est jamais servi
  # pour un autre) tient par la meme comparaison, au meme moment.
  test "JG-066 : N rotations de jeton ne font pas croitre le cache lineairement en N" do
    # ⚠ LE COMPTEUR NE DOIT PAS CONNAITRE LA FORME DU FIX. Ecrit d'abord en
    # `match?({{_, :bot_login, _}, _}, &1)` — une cle a TROIS elements, celle d'apres le correctif —
    # il comptait ZERO sous la mutation, dont la cle en a quatre. Meme retour des deux cotes, test
    # vacuous, mutation verte. On compte toute entree dont la cle porte `:bot_login`, quelle que soit
    # son arite : c'est ce qui differe entre les deux mondes, et rien d'autre.
    #
    # Et on appelle `login_of/1` DIRECTEMENT, pas une lecture de haut niveau : c'est la fonction dont
    # le cache est en cause, et une route qui ne la traverserait pas rendrait le compte nul des deux
    # cotes — vacuous une seconde fois.
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

  # JG-089 — LE DEPOT NE CONNAISSAIT PAS LE `429`. Recherche exhaustive, deux moyens independants :
  # zero occurrence de `429`, `Retry-After` ou `too many` dans `lib/`. Le statut ressortait donc en
  # `{:http, 429, body}`, indistinct d'un `500`, et un appelant qui abandonne sur erreur abandonnait
  # une condition qui se serait levee seule. `name_permanent/4` nomme deja `412` et `423` comme
  # PERMANENTS ; le `429` est leur exact symetrique et n'avait pas sa phrase.
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

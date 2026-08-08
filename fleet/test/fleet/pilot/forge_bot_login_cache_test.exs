defmodule Fleet.Pilot.ForgeBotLoginCacheTest do
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ForgeClient

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
    a = comments_for("lcars-system") ++ [token: "token-A-#{System.unique_integer([:positive])}"]
    b = comments_for("lcars-other") ++ [token: "token-B-#{System.unique_integer([:positive])}"]

    # `count_signed_step_runs/3` is the shortest public path that resolves the bot login, and its
    # filter is where a wrong login does damage. The plug answers /user for both calls.
    assert {:ok, la} = resolve(a)
    assert {:ok, lb} = resolve(b)

    assert la == "lcars-system"
    assert lb == "lcars-other", "the second token inherited the first one's cached login"
  end

  test "the same token resolves once and is reused" do
    tok = "token-same-#{System.unique_integer([:positive])}"
    opts = comments_for("lcars-system") ++ [token: tok]

    assert {:ok, "lcars-system"} = resolve(opts)
    assert {:ok, "lcars-system"} = resolve(opts)
  end

  defp resolve(opts) do
    # No public accessor for the login; the transport exposes it to the client, so we go through the
    # documented seam rather than reaching into persistent_term (which would test the cache, not the
    # behaviour that depends on it).
    apply(Fleet.Pilot.ForgeClient.Transport, :forge_bot_login, [
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
               forge_bot_login: "lcars-system",
               req_options: [plug: {Whoami, "ignored"}]
             )
  end
end

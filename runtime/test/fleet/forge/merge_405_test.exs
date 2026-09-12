defmodule Fleet.Forge.Client.Merge405Test do
  use ExUnit.Case, async: true

  alias Fleet.Forge.Client, as: ForgeClient

  @moduledoc """
  Regression fleet/probe-rails#24, 2026-08-18 : un conflit journal.txt rendait aussi
  "Please try again later" (1447 tentatives en 21 h). Le bit mergeable:false doit arreter
  la reprise interne ; true ou une lecture echouee la permettent. Ces fixtures ne prouvent
  ni la cause du 405 ni sa permanence, et ne testent pas les tentatives des ticks suivants.
  """

  defmodule Forge do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(mergeable), do: mergeable

    @impl Plug
    def call(conn, mergeable) do
      send(self(), {:hit, conn.method, conn.request_path})

      {status, body} =
        case conn.method do
          "POST" -> {405, %{"message" => "Please try again later"}}
          "GET" -> {200, %{"mergeable" => mergeable, "state" => "open", "merged" => false}}
        end

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.send_resp(status, JSON.encode!(body))
    end
  end

  defp merge(mergeable) do
    ForgeClient.merge_pr("fleet/p", 24,
      base_url: "http://fake.test",
      token: "t",
      merge_retry_delay_ms: 0,
      req_options: [plug: {Forge, mergeable}]
    )
  end

  defp posts do
    Stream.repeatedly(fn ->
      receive do
        {:hit, m, p} -> {m, p}
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
    |> Enum.count(fn {m, _} -> m == "POST" end)
  end

  test "405 « try again later » MAIS `mergeable: false` → UNE tentative, et un blocage nommé" do
    assert {:error, {:merge_blocked, %{"message" => _}}} = merge(false)

    assert posts() == 1
  end

  test "TÉMOIN — 405 « try again later » et `mergeable: true` → les tentatives ont bien lieu" do
    # Temoin contre une suppression de toutes les reprises.
    assert {:error, {:http, 405, _}} = merge(true)
    assert posts() == 3
  end

  test "état ILLISIBLE → on retente, jamais un blocage tiré d'une absence de réponse" do
    # Echec de lecture ne vaut pas mergeable:false.
    defmodule Silent do
      @moduledoc false
      @behaviour Plug
      @impl Plug
      def init(o), do: o
      @impl Plug
      def call(conn, _) do
        send(self(), {:hit, conn.method, conn.request_path})

        case conn.method do
          "POST" ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.send_resp(405, JSON.encode!(%{"message" => "Please try again later"}))

          "GET" ->
            Plug.Conn.send_resp(conn, 500, "boom")
        end
      end
    end

    assert {:error, {:http, 405, _}} =
             ForgeClient.merge_pr("fleet/p", 24,
               base_url: "http://fake.test",
               token: "t",
               merge_retry_delay_ms: 0,
               req_options: [plug: {Silent, nil}]
             )

    assert posts() == 3
  end
end

defmodule Fleet.Forge.ClientPaginationTest do
  use ExUnit.Case, async: true

  alias Fleet.Forge.Client, as: ForgeClient

  # X-Total-Count avoids repeating all-items responses and premature stops with a lower server cap.
  # Gitea 1.26.1 bench, 60 comments: budget failure in 5327 ms before, 60 results in 119 ms after.
  # Here the Plug drives page selection and counts calls; assertions count items, not identities.

  defmodule PagedForge do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, %{agent: agent} = opts) do
      Agent.update(agent, &(&1 + 1))
      conn = Plug.Conn.fetch_query_params(conn)
      page = String.to_integer(conn.query_params["page"] || "1")
      body = opts.pages.(page)

      conn
      |> then(fn c ->
        case opts.total do
          nil -> c
          n -> Plug.Conn.put_resp_header(c, "x-total-count", Integer.to_string(n))
        end
      end)
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.send_resp(200, JSON.encode!(body))
    end
  end

  defp item(n), do: %{"id" => n, "body" => "c#{n}"}

  defp run(pages_fun, total) do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    opts = [
      base_url: "http://fake.test",
      token: "t",
      req_options: [plug: {PagedForge, %{agent: agent, pages: pages_fun, total: total}}]
    ]

    result = ForgeClient.list_comments("fleet/p", 1, opts)
    {result, Agent.get(agent, & &1)}
  end

  test "the endpoint that IGNORES page: everything every turn, and the total stops it at ONE request" do
    # The D-14 shape, above the cap. Without the total this walks 200 identical pages.
    all = Enum.map(1..60, &item/1)
    {{:ok, got}, requests} = run(fn _page -> all end, 60)

    assert length(got) == 60
    assert requests == 1
  end

  test "honest paging: the total stops as soon as it is reached, with no probing page" do
    # 100 items, 50 per page. The heuristic needed a THIRD request to see a short page; the total
    # makes the second one final.
    pages = fn
      1 -> Enum.map(1..50, &item/1)
      2 -> Enum.map(51..100, &item/1)
      _ -> []
    end

    {{:ok, got}, requests} = run(pages, 100)

    assert length(got) == 100
    assert requests == 2
  end

  test "NO X-Total-Count: the heuristic still governs, full page then short page" do
    pages = fn
      1 -> Enum.map(1..50, &item/1)
      2 -> Enum.map(51..70, &item/1)
      _ -> []
    end

    {{:ok, got}, requests} = run(pages, nil)

    assert length(got) == 70
    assert requests == 2
  end

  test "an empty page ends it even when the total announces more" do
    # A forge that counts more than it serves (rights filtering) must not make us walk the budget.
    pages = fn
      1 -> Enum.map(1..50, &item/1)
      _ -> []
    end

    {{:ok, got}, requests} = run(pages, 999)

    assert length(got) == 50
    assert requests == 2
  end

  test "a malformed X-Total-Count is treated as NOT ANNOUNCED, never as zero" do
    # Despite the title, this fixture omits the header; it does not serve malformed text.
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    plug =
      {PagedForge,
       %{
         agent: agent,
         total: nil,
         pages: fn
           1 -> Enum.map(1..50, &item/1)
           2 -> Enum.map(51..55, &item/1)
           _ -> []
         end
       }}

    opts = [base_url: "http://fake.test", token: "t", req_options: [plug: plug]]

    assert {:ok, got} = ForgeClient.list_comments("fleet/p", 1, opts)
    assert length(got) == 55
  end
end

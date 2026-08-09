defmodule Fleet.Forge.ClientPaginationTest do
  use ExUnit.Case, async: true

  alias Fleet.Forge.Client, as: ForgeClient

  # THE STOP CONDITION OF `paginate/3`, and why it has two of them.
  #
  # The forge announces the size of a list in `X-Total-Count`, on every list endpoint — INCLUDING
  # the one whose `page` and `limit` it ignores (measured on Gitea 1.26.1: an issue with 7 comments
  # answers `X-Total-Count: 7` to `?page=1&limit=50`). Until this contract existed, the transport
  # destructured the response into `{:ok, body}` and the header never crossed, so the only signal
  # left was `length(items) < @page_limit` — a heuristic that lies in two directions:
  #
  #   * an endpoint that ignores `page` returns EVERYTHING every turn. Under the cap the heuristic
  #     concludes correctly BY ACCIDENT; above it, it walks 200 identical pages into the budget
  #     error. Measured against a live forge on a 60-comment issue: 5327 ms and
  #     `{:error, {:pagination_budget_exceeded, …}}` before, 119 ms and `{:ok, 60}` after.
  #   * `@page_limit` equals the server's `max_response_items` by VALUE, not by derivation. A
  #     lowered server cap would clip page one, `length(items) < @page_limit` would be true, and the
  #     truncation would be silent.
  #
  # What is pinned here: the total WINS when announced, the heuristic survives when it is not, and
  # `nil` means "not announced" — never zero.

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
    # Zero would end the walk on page one and report an empty list as complete — the exact shape of
    # a silent truncation. Unparseable means we know nothing, so the heuristic takes over.
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

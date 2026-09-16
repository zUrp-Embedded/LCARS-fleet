defmodule Fleet.MCP.SupersedeDependenciesTest do
  @moduledoc """
  Supersede copies both dependency directions before closing the old issue.
  Closing first would release dependents before the replacement holds their edges.
  Recorded positions check this ordering; selective receives in other cases only
  check call presence, including the live-PR case.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools

  # Records the ORDER of the forge writes: that is the property under test, not just their presence.
  defmodule OrderForge do
    def issue_dependencies(_repo, 16, _opts), do: {:ok, [%{"number" => 4}]}
    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}

    def issue_blocks(_repo, 16, _opts), do: {:ok, [%{"number" => 9}]}
    def issue_blocks(_repo, _n, _opts), do: {:ok, []}

    def remove_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}

    def add_issue_dependency(_repo, number, blocker, _opts) do
      send(self(), {:edge, number, blocker})
      {:ok, %{}}
    end

    def post_comment(_repo, n, _body, _opts) do
      send(self(), {:comment, n})
      {:ok, :posted}
    end

    def close_issue(_repo, n, _opts) do
      send(self(), {:close, n})
      {:ok, :closed}
    end
  end

  # The forge refuses one edge: the supersede must NOT close the old ticket. A half-rewired
  # supersede that closes anyway is the exact hole this carries.
  defmodule RefusingForge do
    def issue_dependencies(_repo, _n, _opts), do: {:ok, [%{"number" => 4}]}
    def issue_blocks(_repo, _n, _opts), do: {:ok, []}
    def remove_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:error, {:http, 500, "boom"}}

    def post_comment(_repo, n, body, _opts) do
      send(self(), {:comment, n, body})
      {:ok, :posted}
    end

    def close_issue(_repo, n, _opts) do
      send(self(), {:close, n})
      {:ok, :closed}
    end
  end

  # Gitea 1.26 rend 500, PAS 409, quand l'arete est deja la (mesure du 2026-09-16, banc 2002).
  defmodule AlreadyForge do
    def issue_dependencies(_repo, _n, _opts), do: {:ok, [%{"number" => 4}]}
    def issue_blocks(_repo, _n, _opts), do: {:ok, []}
    def remove_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}

    def add_issue_dependency(_repo, _n, _b, _opts),
      do:
        {:error,
         {:http, 500,
          %{"message" => "issue dependency does already exist [issue id: 2, dep id: 3]"}}}

    def post_comment(_repo, n, body, _opts) do
      send(self(), {:comment, n, body})
      {:ok, :posted}
    end

    def close_issue(_repo, n, _opts) do
      send(self(), {:close, n})
      {:ok, :closed}
    end
  end

  # HTTP 409 models replay success; this test does not verify whether an edge actually exists.
  defmodule ConflictForge do
    def issue_dependencies(_repo, _n, _opts), do: {:ok, [%{"number" => 4}]}
    def issue_blocks(_repo, _n, _opts), do: {:ok, []}
    def remove_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:error, {:http, 409, "already"}}
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}

    def close_issue(_repo, n, _opts) do
      send(self(), {:close, n})
      {:ok, :closed}
    end
  end

  defp retire(forge),
    do:
      PodTools.Delegation.Retirement.retire_superseded(forge, "fleet/p", 16, :open, %{
        "issue" => 17
      })

  defp retire_with_pr(forge),
    do:
      PodTools.Delegation.Retirement.retire_superseded(forge, "fleet/p", 16, {:open, 21}, %{
        "issue" => 17
      })

  describe "carrying the edges" do
    test "both directions are rewritten onto the replacement" do
      assert %{"supersedes" => 16} = retire(OrderForge)

      # what the old one depended on -> the replacement depends on it
      assert_received {:edge, 17, 4}
      # what the old one blocked -> that issue now depends on the replacement
      assert_received {:edge, 9, 17}
      assert_received {:comment, 16}
      assert_received {:close, 16}
    end

    test "the close comes AFTER the edges — a release before the rewiring is the defect itself" do
      retire(OrderForge)

      # Compare trace positions; disjoint selective receive patterns would pass after an order reversal.
      trace = drain_mailbox()

      aretes = for {m, i} <- Enum.with_index(trace), match?({:edge, _, _}, m), do: i
      close = Enum.find_index(trace, &match?({:close, 16}, &1))

      assert length(aretes) == 2, "les deux aretes doivent etre ecrites : #{inspect(trace)}"
      assert close, "le ticket doit etre ferme : #{inspect(trace)}"

      assert Enum.max(aretes) < close,
             "la fermeture PRECEDE un recablage — c'est la fenetre de dispatch que ce temoin " <>
               "existe pour fermer : #{inspect(trace)}"
    end
  end

  # ⚠ CE TEMOIN DISAIT L'INVERSE, ET LA MESURE DU BANC A TRANCHE. Un retrait qui s'arrete sur une
  # arete laisse le ticket remplace OUVERT : la fleet le redispatche, et la meme brique est livree
  # deux fois — cinq supersedes en echec sur un projet du banc beta, deux livraisons jumelles. Un
  # zombie coute un lot entier, une arete non portee coute une ligne a reposer. Le retrait va donc
  # au bout, et l'arete qu'il n'a pas pu porter est DITE sur le ticket.
  describe "quand une arete ne peut pas etre portee" do
    test "le retrait va au bout, et l'arete non portee est dite sur le ticket" do
      result = retire(RefusingForge)

      assert_received {:close, 16}
      assert %{"supersedes" => 16} = result
      refute Map.has_key?(result, "supersede_warning")
      assert_received {:comment, 16, corps}
      assert corps =~ "NON portée"
      assert corps =~ "#4"
    end

    test "500 « does already exist » : l'arete EST portee, et rien ne se dit" do
      retire(AlreadyForge)

      assert_received {:close, 16}
      assert_received {:comment, 16, corps}
      refute corps =~ "NON portée"
    end
  end

  describe "replay" do
    test "an edge the replacement already carries is nominal — the close still happens" do
      assert %{"supersedes" => 16} = retire(ConflictForge)
      assert_received {:close, 16}
    end
  end

  # Pull processing is independent; retiring a ticket must also close its live PR.
  defmodule PrForge do
    def close_pr(_repo, pr, _opts) do
      send(self(), {:pr_closed, pr})
      {:ok, :closed}
    end

    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}
    def issue_blocks(_repo, _n, _opts), do: {:ok, []}
    def remove_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}

    def post_comment(_repo, n, _body, _opts) do
      send(self(), {:comment, n})
      {:ok, :posted}
    end

    def close_issue(_repo, n, opts) do
      send(self(), {:close, n, Keyword.get(opts, :closure)})
      {:ok, :closed}
    end
  end

  defmodule PrRefusingForge do
    def close_pr(_repo, _pr, _opts), do: {:error, {:http, 500, "boom"}}
    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}
    def issue_blocks(_repo, _n, _opts), do: {:ok, []}
    def remove_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}

    def close_issue(_repo, n, _opts) do
      send(self(), {:close, n})
      {:ok, :closed}
    end
  end

  describe "cible avec une PR vivante" do
    test "la PR est fermee AVANT le ticket — tant qu'elle vit, elle peut etre mergee" do
      assert %{"supersedes" => 16} = retire_with_pr(PrForge)

      assert_received {:pr_closed, 21}
      assert_received {:comment, 16}
      assert_received {:close, 16, :retired}
    end

    test "PR non fermable -> le ticket reste OUVERT : le geste incomplet ne s'execute pas a moitie" do
      result = retire_with_pr(PrRefusingForge)

      refute_received {:close, 16}
      assert result["supersede_warning"] =~ "encore ouvert"
    end

    test "sans PR vivante, rien n'est ferme cote pulls" do
      retire(OrderForge)
      refute_received {:pr_closed, _}
    end
  end

  # Drain same-process sends in order to compare call positions.
  defp drain_mailbox(acc \\ []) do
    receive do
      msg -> drain_mailbox([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

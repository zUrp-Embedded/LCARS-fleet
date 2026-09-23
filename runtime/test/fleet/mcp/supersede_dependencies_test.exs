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
    def add_label(_repo, n, label, _opts) do
      send(self(), {:stamp, n, label})
      {:ok, :added}
    end

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
    def add_label(_repo, n, label, _opts) do
      send(self(), {:stamp, n, label})
      {:ok, :added}
    end

    def issue_dependencies(_repo, 16, _opts), do: {:ok, [%{"number" => 4}]}
    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}
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
    def add_label(_repo, n, label, _opts) do
      send(self(), {:stamp, n, label})
      {:ok, :added}
    end

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
    def add_label(_repo, n, label, _opts) do
      send(self(), {:stamp, n, label})
      {:ok, :added}
    end

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
    def add_label(_repo, n, label, _opts) do
      send(self(), {:stamp, n, label})
      {:ok, :added}
    end

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
    def add_label(_repo, n, label, _opts) do
      send(self(), {:stamp, n, label})
      {:ok, :added}
    end

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

    test "PR non fermable -> le ticket reste OUVERT mais TAMPONNE : il ne repart jamais" do
      result = retire_with_pr(PrRefusingForge)

      refute_received {:close, 16}
      assert_received {:stamp, 16, "stage/retired"}
      assert result["supersede_warning"] =~ "pull_request"
      assert result["supersede_warning"] =~ "issue_retire(16)"
    end

    test "sans PR vivante, rien n'est ferme cote pulls" do
      retire(OrderForge)
      refute_received {:pr_closed, _}
    end
  end

  # ── The 2026-09-23 case, replayed ──
  # #12 waits on #13 (open). #14 supersedes it and ALREADY waits on #13 (created with depends_on).
  # Two forge behaviours measured on that day, and nothing else invented:
  #   - closing an issue that still has open dependencies → HTTP 412 with this exact message;
  #   - writing an edge that already exists → HTTP 500 with an EMPTY message.
  # Before: the retirement closed first (412), the ticket stayed open without any marker, and the
  # warning said « Dépendance(s) NON portée(s) : - #13 : » — empty, and false.
  defmodule Sept23Forge do
    @moduledoc false
    def edges, do: Process.get(:edges, MapSet.new([{12, 13}, {14, 13}]))
    defp put_edges(e), do: Process.put(:edges, e)

    def issue_dependencies(_repo, n, _opts),
      do: {:ok, for({^n, b} <- edges(), do: %{"number" => b})}

    def issue_blocks(_repo, n, _opts), do: {:ok, for({d, ^n} <- edges(), do: %{"number" => d})}

    def add_issue_dependency(_repo, n, b, _opts) do
      send(self(), {:edge, n, b})

      if MapSet.member?(edges(), {n, b}),
        do: {:error, {:http, 500, %{"message" => ""}}},
        else: {:ok, put_edges(MapSet.put(edges(), {n, b}))}
    end

    def remove_issue_dependency(_repo, n, b, _opts) do
      send(self(), {:lift, n, b})
      {:ok, put_edges(MapSet.delete(edges(), {n, b}))}
    end

    def close_issue(_repo, n, _opts) do
      if Enum.any?(edges(), &match?({^n, _}, &1)) do
        {:error,
         {:http, 412,
          %{
            "message" =>
              "cannot close this issue or pull request because it still has open dependencies"
          }}}
      else
        send(self(), {:close, n})
        {:ok, :closed}
      end
    end

    def add_label(_repo, n, label, _opts) do
      send(self(), {:stamp, n, label})
      {:ok, :added}
    end

    def post_comment(_repo, n, body, _opts) do
      send(self(), {:comment, n, body})
      {:ok, :posted}
    end
  end

  describe "le cas du 2026-09-23, rejoué" do
    test "un ticket bloqué par un ticket ouvert se retire : ses bloqueurs sont levés AVANT la fermeture" do
      result = retire_sept23(Sept23Forge, 12, 14)

      assert %{"supersedes" => 12} = result
      refute Map.has_key?(result, "supersede_warning")
      assert_received {:close, 12}
      assert_received {:lift, 12, 13}
      refute MapSet.member?(Sept23Forge.edges(), {12, 13})
    end

    test "l'arête que le successeur porte DÉJÀ n'est ni réécrite ni dite « non portée »" do
      retire_sept23(Sept23Forge, 12, 14)

      refute_received {:edge, 14, 13}
      assert_received {:comment, 12, corps}
      refute corps =~ "NON portée"
      assert corps =~ "Remplacé par #14"
    end
  end

  defp retire_sept23(forge, old, new),
    do:
      Fleet.MCP.PodTools.Delegation.Retirement.retire_superseded(forge, "fleet/p", old, :open, %{
        "issue" => new
      })

  # Drain same-process sends in order to compare call positions.
  defp drain_mailbox(acc \\ []) do
    receive do
      msg -> drain_mailbox([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

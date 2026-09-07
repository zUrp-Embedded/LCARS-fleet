defmodule Fleet.MCP.SupersedeDependenciesTest do
  @moduledoc """
  A supersede must CARRY the dependency edges to the replacement, and must do it BEFORE closing.

  Why the order is the contract, not a preference: a Gitea dependency links two issue_ids, and
  `supersedes` is not a forge primitive — it is an LCARS convention (comment + close). The forge
  therefore sees no replacement: it sees one issue die and another appear, and the edges stay on
  the dead one. Closing first RELEASES everything the old ticket blocked (a closed blocker counts
  as satisfied) while the work has moved and is not delivered — and a dispatch can slip into that
  window. Measured on the bench 2026-08-04.
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

    def post_comment(_repo, n, _body, _opts) do
      send(self(), {:comment, n})
      {:ok, :posted}
    end

    def close_issue(_repo, n, _opts) do
      send(self(), {:close, n})
      {:ok, :closed}
    end
  end

  # An edge already present on the replacement (replay) is NOMINAL, not a failure.
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

      # ⚠ CE TEMOIN PORTAIT LE NOM DE L'ORDRE ET NE TESTAIT QUE LA PRESENCE. `assert_received`
      # balaie la boite aux lettres pour CHAQUE motif INDEPENDAMMENT : quatre motifs disjoints
      # reussissent quel que soit l'ordre d'arrivee. Le commentaire d'avant — « the mailbox order
      # IS the write order » — disait vrai de la BOITE, pas des assertions qui la lisent.
      # Mutation jouee le 2026-09-07 : fermer le ticket AVANT de recabler les dependances laissait
      # ce temoin ET son voisin verts, alors que la fenetre de dispatch ainsi ouverte est le defaut
      # que `do_retire/5` documente en toutes lettres.
      #
      # Meme lecon, meme forme que `retire_issue_test` (mesure du 2026-08-08) : on VIDE la boite —
      # elle EST la trace de l'ordre d'appel, meme processus, envois synchrones — et on compare des
      # POSITIONS.
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

  describe "when the rewiring cannot be done" do
    test "the old ticket stays OPEN and the result says so — loud beats wrong" do
      result = retire(RefusingForge)

      refute_received {:close, 16}
      assert result["supersede_warning"] =~ "encore ouvert"
    end
  end

  describe "replay" do
    test "an edge the replacement already carries is nominal — the close still happens" do
      assert %{"supersedes" => 16} = retire(ConflictForge)
      assert_received {:close, 16}
    end
  end

  # ─── La PR vivante meurt avec son ticket ────────────────────────────────────────────────────
  # Le rail des pulls est INDÉPENDANT (`dispatch_review` scrute les pulls, hors bail) : une PR
  # laissée ouverte sur un ticket retiré continue d'être jugée puis mergée. L'ancien refus
  # (`supersedes_target_in_flight`) protégeait de ça en interdisant le geste — c'était un
  # contournement du fait que rien ne savait fermer une PR.
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

  # La boite aux lettres videe DANS L'ORDRE : la seule facon de juger un ordre d'ecriture avec des
  # motifs disjoints (cf. le temoin ci-dessus). Jumeau de `retire_issue_test`.
  defp drain_mailbox(acc \\ []) do
    receive do
      msg -> drain_mailbox([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

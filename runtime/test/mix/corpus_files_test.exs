defmodule Mix.Tasks.Lcars.Contracts.CorpusFilesTest do
  @moduledoc """
  `Support.corpus_files/1`, le parcours que trois murs partagent : ce qu'il ELAGUE, prouve sur un
  arbre fabrique.

  Personne ne le temoignait. Il a fallu que dix worktrees parques sous `.claude/mut/` fassent rougir
  la suite (3 temoins « contre le depot reel », 190 repertoires accuses) pour que son contrat soit
  ecrit : les artefacts de build sont sautes PAR NOM a toute profondeur, et un DEPOT IMBRIQUE —
  un enfant qui porte un `.git`, fichier ou dossier — est ferme en entier. Un mur dont le verdict
  depend de ce que l'operateur a parque dans l'arbre mesure la machine, pas le depot.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Support

  defp arbre(fichiers) do
    root = Fleet.TestEnv.tmp_path("corpus_files")
    on_exit(fn -> File.rm_rf!(root) end)

    for {rel, contenu} <- fichiers do
      chemin = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(chemin))
      File.write!(chemin, contenu)
    end

    root
  end

  defp relatifs(root),
    do: root |> Support.corpus_files() |> Enum.map(&Path.relative_to(&1, root)) |> Enum.sort()

  test "un worktree imbrique (`.git` FICHIER) est ferme en entier — ses freres ne sont pas le corpus" do
    root =
      arbre([
        {"test/a_test.exs", ""},
        # la forme exacte d'un `git worktree add` : un fichier `.git` qui pointe ailleurs
        {"wt/.git", "gitdir: /ailleurs/.git/worktrees/wt\n"},
        {"wt/runtime/test/b_test.exs", ""},
        {"wt/deploy/tests/c.bats", ""}
      ])

    assert relatifs(root) == ["test/a_test.exs"]
  end

  test "un clone vendore (`.git` DOSSIER) est ferme aussi" do
    root =
      arbre([
        {"test/a_test.exs", ""},
        {"vendored/.git/HEAD", "ref: refs/heads/main\n"},
        {"vendored/test/d_test.exs", ""}
      ])

    assert relatifs(root) == ["test/a_test.exs"]
  end

  test "⚠ LA RACINE N'EST PAS UN DEPOT IMBRIQUE — son propre `.git` ne ferme rien" do
    # Un garde ecrit « un dossier qui contient .git est ferme » et applique a la racine rendrait un
    # corpus VIDE sur tout depot git — et vide, pour trois murs, se lit « rien a redire ».
    root = arbre([{".git", "gitdir: /ailleurs\n"}, {"test/a_test.exs", ""}])

    assert relatifs(root) == ["test/a_test.exs"]
  end

  test "les artefacts de build sont sautes PAR NOM, a toute profondeur" do
    root =
      arbre([
        {"test/a_test.exs", ""},
        {"_build/x.beam", ""},
        {"deps/y/z.ex", ""},
        {"runtime/tmp/residu.exs", ""},
        {"runtime/test/e_test.exs", ""}
      ])

    assert relatifs(root) == ["runtime/test/e_test.exs", "test/a_test.exs"]
  end

  test "une racine illisible rend une liste vide, pas une exception" do
    assert Support.corpus_files(Fleet.TestEnv.tmp_path("corpus_files_absent")) == []
  end
end

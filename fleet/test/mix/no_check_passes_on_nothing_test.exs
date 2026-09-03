defmodule Mix.Tasks.Lcars.Contracts.NoCheckPassesOnNothingTest do
  @moduledoc """
  No wall may report compliance about a tree it never opened.

  Measured 2026-08-06 by pointing the checker at an empty directory: SEVEN of twenty-nine checks
  returned `:pass`. All the same shape — absence-of-violation walls with no population guard, where
  zero subjects and zero violations are indistinguishable at the output. It was not hypothetical:
  twice that night a subject had moved out from under its instrument (a tidying commit relocated the
  v1 corpus and killed 447 cases; two bats suites had never been in any gate), and these were the
  walls that would have said green about it.

  The guards were added. This test exists so the EIGHTH occurrence does not depend on someone being
  curious again — it enumerates the checks by reflection, so a check added tomorrow is covered
  without anyone remembering to add it here.

  A check that RAISES on an empty tree passes this test on purpose. Raising is fail-loud: the task
  dies, the gate dies, and the release step already refuses on an unknown contract status. What is
  forbidden is the quiet green.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check

  # The admissible `:pass` on nothing, admissible because it SAYS so: the note reads "NOT CHECKED
  # here (deploy absent from this artifact — runtime-only context)". A pass that declares it
  # looked at nothing is an answer; a pass that stays silent about it is the defect.
  #
  # THIS LIST IS AN ALLOW-LIST BY ID, NOT A NOTE-SNIFFER, AND THAT IS DELIBERATE. Matching on the
  # wording would let any check earn its exemption by writing the magic sentence; naming the id
  # makes each exemption a decision someone had to write down and a reviewer can see. The cost is
  # that this list must be edited when a check of this shape is added — which is exactly the moment
  # to ask whether the exemption is warranted.
  #
  # The three entries share ONE cause: their subject is `deploy`, which the image's `build`
  # stage excludes on purpose (a compose edit would otherwise invalidate the layer and repay a ~10
  # min gate). They are checks about the MACHINE, played inside an artifact that does not carry it.
  #
  # `toolchain.branch_single_source` joined on 2026-08-19 and its exemption was weighed here, as
  # this comment asks. Its authority — the frozen literal in `Fleet.Toolchain.branch/0` — DOES ship
  # in the artifact, and the check fails loudly when that literal becomes unreadable. A copy that is
  # not in the tree has nothing to judge. Same shape, same cause, same answer.
  #
  # ⚠ ITS EXEMPTION IS NARROWER SINCE 2026-08-27, AND THIS COMMENT IS WHAT WAS WRONG. It read "what
  # it cannot see is the THREE SHELL COPIES" — the check held four copies then, two of which
  # (`services/`, `bin/`) the image's build stage DOES carry, since it excludes only `deploy`,
  # `git-hooks` and `system-prompt`. The check now scopes PER MIRROR, so this entry earns the
  # exemption only on a root with no mirror tree at all — an empty one, which is exactly what this
  # test builds. A count written in prose is a claim, and this one had drifted by one and by kind.
  # ⚠ DEUX ENTREES AJOUTEES LE 2026-08-27, ET ELLES N'ONT PAS CHANGE DE COMPORTEMENT — ELLES SONT
  # DEVENUES VISIBLES. `bats.descriptions_inert` et `site.build_inputs` etaient `defp`, donc hors de
  # la reflexion, donc hors de la garantie que ce fichier annonce. Les deux declaraient DEJA leur
  # abstention par ecrit (« HORS PERIMETRE — pas de suite bats ici », « HORS PERIMETRE —
  # assets/github.io absent de cet arbre »), et leur cause est la meme que les trois du dessus : un
  # arbre voisin que le stage `build` de l'image ne copie pas. Le troisieme invisible,
  # `template.gitea_expansion`, N'EST PAS ICI : il ne declarait rien, il est passe fail-closed.
  # ⚠ `layout.private_dir_single_source` A ETE ATTRAPE PAR CE FICHIER LE JOUR DE SON ECRITURE, et
  # c'est le garde renforce le matin meme qui l'a vu. Son exemption est pesee ici, comme ce
  # commentaire l'exige, et elle n'a PAS la meme cause que les cinq du dessus.
  #
  # Ce check ne compare pas des copies a une autorite : il verifie que N declarations d'un meme
  # repertoire s'ACCORDENT — aucune n'a ete designee comme faisant foi. En dessous de DEUX
  # declarations lisibles, il n'y a pas d'accord a verifier : ni faute, ni preuve. Sur un arbre
  # vide il y en a zero ; dans l'artefact runtime il y en a UNE (le `@default_dir` du BEAM), les
  # quatre autres vivant sous `deploy/`.
  #
  # Le rendre fail-closed la ferait rougir la construction de l'image sur un artefact CORRECT —
  # exactement la faute que `site.build_inputs` documente deux lignes plus haut, et qui a deja
  # coute un build. Il passe donc, EN LE DISANT, et sa note nomme les declarations qu'il n'a pas vues.
  @declares_it_did_not_measure [
    "shell.sourcers_set_strict",
    "layout.face_roots_provisioned",
    "toolchain.branch_single_source",
    "bats.descriptions_inert",
    "site.build_inputs",
    "layout.private_dir_single_source"
  ]

  defp empty_root do
    root = Fleet.TestEnv.tmp_path("no_pass")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp check_functions do
    Check.__info__(:functions)
    |> Enum.filter(fn {name, arity} ->
      arity == 1 and String.starts_with?(Atom.to_string(name), "check_")
    end)
    |> Enum.map(&elem(&1, 0))
  end

  test "every check either fails, raises, or SAYS it measured nothing — none is quietly green" do
    root = empty_root()

    quietly_green =
      check_functions()
      |> Enum.map(fn fun ->
        try do
          {fun, apply(Check, fun, [root])}
        rescue
          # Fail-loud is an acceptable answer on an empty tree: the task dies and takes the gate
          # with it. Only silence is refused.
          _ -> {fun, :raised}
        catch
          _, _ -> {fun, :raised}
        end
      end)
      |> Enum.filter(fn
        {_fun, %{status: :pass, id: id}} -> id not in @declares_it_did_not_measure
        _ -> false
      end)
      |> Enum.map(fn {fun, %{id: id}} -> "#{fun} → #{id}" end)

    assert quietly_green == [],
           "these checks returned :pass on an EMPTY tree, so they report compliance about a set " <>
             "they never had: #{inspect(quietly_green)}. Count the population before judging it — " <>
             "`measured_nothing?/1` + `broken_result/2` are the shape used by the others."
  end

  test "the enumeration is REAL — reflection finds every check the task runs" do
    # Guard on the guard. If the reflection filter stopped matching (a rename, a change of arity),
    # the test above would iterate an empty list and pass while measuring nothing — the exact defect
    # it exists to catch, arriving inside it.
    found = check_functions()

    # ⚠ CE GARDE ETAIT UN PLANCHER A 25 PENDANT QUE LA TACHE EN JOUAIT 58, ET C'EST CE QUI A LAISSE
    # PASSER LE TROU. `__info__(:functions)` ne voit que les fonctions PUBLIQUES : trois checks
    # d'arite 1 etaient `defp`, donc invisibles a la reflexion — la garantie « aucun check ne passe
    # sur rien » ne couvrait que 55 des 58, et l'un des trois (`template.gitea_expansion`) rendait
    # bel et bien un vert muet sur un repertoire renomme. Un plancher a 25 ne pouvait pas le voir :
    # 55 >= 25.
    #
    # Le garde COMPTE DESORMAIS CE QUE LA TACHE APPELLE, dans sa propre source. Un check ajoute a
    # `run_checks` sans etre joignable par reflexion — parce qu'il est prive — rougit ici, au lieu
    # d'echapper en silence a la garantie que ce fichier annonce.
    called = called_check_names()

    assert MapSet.subset?(MapSet.new(called), MapSet.new(found)),
           "checks appeles par run_checks mais INVISIBLES a la reflexion (donc hors de la " <>
             "garantie de ce fichier) : " <>
             inspect(Enum.sort(called -- found)) <>
             " — un check d'arite 1 doit etre `def`, pas `defp`"

    assert length(found) >= 25, "only #{length(found)} check functions found by reflection"
    assert :check_test_corpora_on_record in found
  end

  # Les `check_*(root)` que `run_checks/0` appelle, lus dans la source de la tache. C'est la MEME
  # famille de mesure que les contrats eux-memes : la liste d'appels est la seule autorite sur « ce
  # que le gate joue », et la recopier ici en ferait une seconde qui derive.
  defp called_check_names do
    src = File.read!(Path.join(File.cwd!(), "lib/mix/tasks/lcars.contracts.check.ex"))
    [_, body] = Regex.run(~r/def run_checks do\n(.*?)\n  end\n/s, src)

    ~r/^\s*(check_[a-z0-9_]+)\(root\),?$/m
    |> Regex.scan(body)
    |> Enum.map(fn [_, name] -> String.to_atom(name) end)
    |> Enum.uniq()
  end
end

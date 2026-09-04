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
  # ⚠ ITS EXEMPTION IS NARROW: the check scopes PER MIRROR (`services/` and `bin/` ship in the
  # image, whose build stage excludes only `deploy`, `git-hooks` and `system-prompt`), so this entry
  # earns the exemption only on a root with no mirror tree at all — an empty one, which is exactly
  # what this test builds. A count written in prose is a claim, and one here has drifted before.
  # ⚠ `bats.descriptions_inert` ET `site.build_inputs` SONT `def`, PAS `defp` — sinon hors de la
  # reflexion, donc hors de la garantie que ce fichier annonce. Les deux declarent leur abstention
  # par ecrit (« HORS PERIMETRE — pas de suite bats ici », « HORS PERIMETRE — assets/github.io
  # absent de cet arbre »), et leur cause est la meme que les trois du dessus : un arbre voisin que
  # le stage `build` de l'image ne copie pas. `template.gitea_expansion` N'EST PAS ICI : il ne
  # declare rien, il passe fail-closed.
  # ⚠ `layout.private_dir_single_source` : son exemption est pesee ici, comme ce commentaire
  # l'exige, et elle n'a PAS la meme cause que les cinq du dessus.
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

  # Les `{module, fonction}` joignables par reflexion, dans CHAQUE module que `run_checks/0` nomme.
  # La liste des modules n'est pas ecrite ici : elle se lit dans les appels, comme le reste.
  defp check_functions do
    called_checks()
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.flat_map(fn mod ->
      mod.__info__(:functions)
      |> Enum.filter(fn {name, arity} ->
        arity == 1 and String.starts_with?(Atom.to_string(name), "check_")
      end)
      |> Enum.map(fn {name, _arity} -> {mod, name} end)
    end)
  end

  test "every check either fails, raises, or SAYS it measured nothing — none is quietly green" do
    root = empty_root()

    quietly_green =
      check_functions()
      |> Enum.map(fn {mod, fun} ->
        try do
          {fun, apply(mod, fun, [root])}
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

    # ⚠ LE GARDE COMPTE CE QUE LA TACHE APPELLE, PAS UN PLANCHER. `__info__(:functions)` ne voit que
    # les fonctions PUBLIQUES : un plancher (mesure : 25, pendant que la tache jouait 58 checks) ne
    # voit pas trois checks `defp` invisibles a la reflexion — la garantie « aucun check ne passe
    # sur rien » ne couvre alors que 55 des 58, et l'un des trois (`template.gitea_expansion`)
    # rendait bel et bien un vert muet sur un repertoire renomme. 55 >= 25 : un plancher ne le voit
    # pas.
    #
    # Le garde compte donc dans la source de la tache elle-meme. Un check ajoute a
    # `run_checks` sans etre joignable par reflexion — parce qu'il est prive — rougit ici, au lieu
    # d'echapper en silence a la garantie que ce fichier annonce.
    called = called_checks()

    # ⚠ LE GARDE DU GARDE. Reconnaitre les appels par un motif rend ce fichier vulnerable a une
    # FORME d'appel qu'il ne connait pas : `called` retrecit, l'inclusion ci-dessous reste vraie, et
    # rien ne rougit. C'est arrive au premier decoupage. On compte donc aussi les appels par un
    # motif DELIBEREMENT lache — n'importe quel `check_x(root)`, prefixe ou non — et les deux
    # comptes doivent coincider. Une forme non reconnue creuse un ecart au lieu de disparaitre.
    assert length(called) == length(loose_check_calls()),
           "le motif de `called_checks/0` ne reconnait pas toutes les formes d'appel de " <>
             "`run_checks/0` : #{length(called)} reconnus pour #{length(loose_check_calls())} " <>
             "appels presents. Un mur invisible a ce fichier est un mur hors garantie"

    assert MapSet.subset?(MapSet.new(called), MapSet.new(found)),
           "checks appeles par run_checks mais INVISIBLES a la reflexion (donc hors de la " <>
             "garantie de ce fichier) : " <>
             inspect(Enum.sort(called -- found)) <>
             " — un check d'arite 1 doit etre `def`, pas `defp`, dans le module qui le porte"

    # ⚠ ET L'INCLUSION INVERSE, qui manquait. La ligne au-dessus tient « tout ce qui est APPELE est
    # visible » ; sans celle-ci, un mur PUBLIC ajoute a un module de la famille mais jamais cable
    # dans `run_checks/0` passe inapercu : il est propre sur un arbre vide, il ne rougit nulle
    # part, et il ne s'execute JAMAIS. Un mur qui ne tourne pas ne garde rien, et c'est le mode de
    # defaillance le plus silencieux de ce fichier.
    assert MapSet.subset?(MapSet.new(found), MapSet.new(called)),
           "checks PUBLICS jamais appeles par `run_checks/0`, donc jamais joues : " <>
             inspect(Enum.sort(found -- called)) <>
             " — ajoute-les a la chaine, ou rends-les prives s'ils sont des helpers"

    assert length(found) >= 25, "only #{length(found)} check functions found by reflection"
    assert {Check.Tests, :check_test_corpora_on_record} in found
  end

  # Les `check_*(root)` que `run_checks/0` appelle, lus dans la source de la tache, AVEC le module
  # qui les porte. C'est la MEME famille de mesure que les contrats eux-memes : la liste d'appels
  # est la seule autorite sur « ce que le gate joue », et la recopier ici en ferait une seconde qui
  # derive.
  #
  # ⚠ LE PREFIXE DE FAMILLE EST LU, PAS SUPPOSE ABSENT. Un mur vit dans `Check`, `Check.SingleSource`
  # ou `Check.Tests` ; un motif qui n'accepterait que l'appel NU cesserait de voir huit murs au
  # premier deplacement, la liste `called` retrecirait, l'inclusion `called ⊆ found` resterait vraie
  # et le gate resterait VERT (mesure au decoupage du 2026-09-02). Un garde qui retrecit en silence
  # est la panne exacte que ce fichier existe pour empecher, arrivee a l'interieur de lui.
  # Le meme corps, compte par un motif qui ne suppose RIEN du prefixe. Sert uniquement de temoin de
  # completude a `called_checks/0` — il ne dit pas dans quel module vit le mur, seulement qu'il est
  # appele.
  defp loose_check_calls do
    ~r/(?:^|\s|\.)(check_[a-z0-9_]+)\(root\)/m
    |> Regex.scan(run_checks_body())
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
  end

  defp run_checks_body do
    src = File.read!(Path.join(File.cwd!(), "lib/mix/tasks/lcars.contracts.check.ex"))
    [_, body] = Regex.run(~r/def run_checks do\n(.*?)\n  end\n/s, src)
    body
  end

  defp called_checks do
    body = run_checks_body()

    ~r/^\s*(?:([A-Z][A-Za-z0-9_.]*)\.)?(check_[a-z0-9_]+)\(root\),?$/m
    |> Regex.scan(body)
    |> Enum.map(fn
      [_, "", name] -> {Check, String.to_atom(name)}
      [_, family, name] -> {Module.concat(Check, family), String.to_atom(name)}
    end)
    |> Enum.uniq()
  end
end

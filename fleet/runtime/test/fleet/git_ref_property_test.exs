defmodule Fleet.GitRefPropertyTest do
  @moduledoc """
  Preuve property-based de la primitive de validation de ref. `git_ref_test.exs` fixe des cas
  nommés ; ici on prouve le sens qui COMPTE — le FAUX-ACCEPT.

  Le module existe pour empêcher un nom malformé d'atteindre un `git clone`/`push`/`commit`
  réel. Un faux-REJET est bénin (on refuse une ref que git aurait prise : le clone ne part pas,
  c'est bruyant). Un faux-ACCEPT est la panne : la ref part vers git, qui la refuse au fond du
  tuyau, ou pire l'interprète (cf. la cicatrice acte4 #39 — `"main\\n"` déclarée valide par des
  ancres `^…$`). L'oracle de la property est donc `git` LUI-MÊME : ce que `valid?` accepte,
  `git check-ref-format --branch` doit l'accepter.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.GitRef

  # ── générateurs ──

  # Composant sain : le charset que `@ref_re` autorise entre les `/`.
  defp component do
    string([?a..?z, ?A..?Z, ?0..?9, ?., ?_, ?-], min_length: 1, max_length: 6)
  end

  # Les poisons : exactement les classes que `check-ref-format` refuse et qu'un regex de charset
  # seul manquerait (`..`, `.lock`, `.` final, composant vide), plus les control-chars/espaces
  # que le charset DOIT exclure, plus les méta-caractères de refspec (`~^:?*[\`, `@{`).
  defp poison do
    member_of([
      "..",
      ".lock",
      ".",
      "/",
      "//",
      "\n",
      "\r",
      "\t",
      "\0",
      " ",
      "-",
      "@{",
      "~",
      "^",
      ":",
      "?",
      "*",
      "[",
      "\\"
    ])
  end

  # Ref générée : 1 à 3 composants sains, avec (souvent) un poison injecté à une position
  # quelconque — tête, milieu ou queue. Les refs SAINES (sans poison) sont dans le tirage : la
  # property différentielle doit aussi prouver qu'on ne sur-serre pas jusqu'au vide.
  defp ref_gen do
    gen all(
          comps <- list_of(component(), min_length: 1, max_length: 3),
          p <- one_of([constant(nil), poison()]),
          pos <- integer(0..30)
        ) do
      base = Enum.join(comps, "/")

      case p do
        nil ->
          base

        p ->
          {head, tail} = String.split_at(base, min(pos, String.length(base)))
          head <> p <> tail
      end
    end
  end

  # ── P2 — PURE (l'invariant sans dépendance externe) ──

  # INVARIANT : toute string portant `..`, un espace ou un control-char est REFUSÉE, où que le
  # poison se trouve (y compris en position terminale).
  # POURQUOI : `..` est la traversée (`refs/heads/../../evil`), l'espace et le control-char sont
  # ce qui casse le parsing de refspec côté git. La position TERMINALE est la cicatrice acte4 #39 :
  # avec des ancres `^…$`, `"main\n"` passait. Cette property la verrouille pour TOUT préfixe.
  property "P2 PURE — `..`, espace ou control-char n'importe où ⇒ valid? == false" do
    check all(
            prefix <- string([?a..?z, ?0..?9], max_length: 6),
            bad <- member_of(["..", " ", "\n", "\r", "\t", "\0", "\v", "\f"]),
            suffix <- string([?a..?z, ?0..?9], max_length: 6)
          ) do
      candidate = prefix <> bad <> suffix

      refute GitRef.valid?(candidate),
             "ref #{inspect(candidate)} doit être refusée (traversée / control-char)"
    end
  end

  # ── P1 — DIFFÉRENTIELLE (oracle = git) ──
  #
  # ⚠ Dépend du binaire `git` (tag :external). Si git est absent de l'environnement, la property
  # est remplacée par un test skippé explicite — jamais un vert silencieux sur un oracle absent.
  #
  # ⚠ FAUX POSITIF ÉCARTÉ (leçon de ce lot) — la 1re version de cette property flaggait
  # `valid?("HEAD") == true` comme un faux-accept, parce que `git check-ref-format --branch HEAD`
  # échoue. Le "fix" a été tenté : 12 tests rouges (Deliverable). `"HEAD"` est LOAD-BEARING —
  # c'est le côté LOCAL de tout push de livrable (`git push <remote> HEAD:refs/heads/<branch>`,
  # `Deliverable.local_ref/1` par défaut). L'oracle `--branch` répond à « peut-on CRÉER une branche
  # de ce nom ? » ; le contrat du module est « est-ce une ref git bien formée ? ». Deux questions
  # différentes : l'écart est un choix ASSUMÉ, pas un défaut. `HEAD` est donc EXCLU du différentiel
  # ci-dessous, sciemment, plutôt que masqué en silence.
  @branch_oracle_exceptions ["HEAD"]

  test "`HEAD` reste une ref VALIDE (côté local du push de livrable) — l'oracle --branch ne s'applique pas" do
    assert GitRef.valid?("HEAD")
  end

  if System.find_executable("git") do
    # INVARIANT : valid?(ref) ⟹ `git check-ref-format --branch ref` sort en 0.
    # POURQUOI : `valid?` PRÉTEND porter « l'autorité git complète » (R2-06), pas un
    # « à peu près aligné ». Toute ref qu'on laisse passer et que git refuse, c'est un
    # `clone`/`push` qui échoue en profondeur, loin du point de saisie, avec un message git
    # opaque au lieu du `{:invalid_ref, ref}` typé que les appelants savent traiter.
    @tag :external
    property "P1 DIFFÉRENTIELLE — valid?(ref) ⟹ git check-ref-format --branch l'accepte" do
      check all(ref <- ref_gen(), max_runs: 300) do
        if GitRef.valid?(ref) and ref not in @branch_oracle_exceptions do
          assert git_accepts_branch?(ref),
                 "valid?(#{inspect(ref)}) == true mais git check-ref-format --branch la REFUSE " <>
                   "— faux-accept : la ref atteindrait un clone/push réel"
        end
      end
    end
  else
    @tag :external
    @tag skip: "binaire `git` absent de l'environnement — oracle indisponible"
    test "P1 DIFFÉRENTIELLE — oracle git" do
      :ok
    end
  end

  # On n'appelle `git` QUE sur les refs que `valid?` a acceptées : elles sont donc garanties
  # sans NUL (que System.cmd refuserait) et sans `-` initial (que git prendrait pour une option).
  defp git_accepts_branch?(ref) do
    {_out, code} =
      System.cmd("git", ["check-ref-format", "--branch", ref],
        stderr_to_stdout: true,
        cd: System.tmp_dir!()
      )

    code == 0
  end
end

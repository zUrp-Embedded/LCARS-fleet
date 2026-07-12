defmodule Fleet.Pilot.IssueIdPropertyTest do
  @moduledoc """
  Preuve property-based du couple `compose/parse` de l'`issue_id`. `issue_id_test.exs`
  énumère 6 entiers câblés ; la property couvre le domaine entier, NÉGATIFS COMPRIS.

  L'`issue_id` corrèle un pod à son issue de forge pendant tout le step_run (enqueue →
  fin de step_run). Un round-trip qui casse, c'est un pod qu'on ne sait plus rattacher à
  son issue : le résultat n'est jamais recollé, et le step_run reste en vol.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.Pilot.IssueId

  # ORACLE — la forme que `parse/1` accepte RÉELLEMENT (constatée, pas postulée). Voir la note
  # d'audit sous P2 : `Integer.parse/1` tolère les zéros de tête et le signe explicite, donc
  # l'oracle n'est PAS `\Aissue-(0|-?[1-9][0-9]*)\z` (la forme canonique de `compose/1`).
  @accepted ~r/\Aissue-[+-]?[0-9]+\z/

  # ── P1 — ROUND-TRIP ──

  # INVARIANT : ∀ n entier, `parse(compose(n)) == {:ok, n}` — y compris n < 0 (`"issue--5"`).
  # POURQUOI : `StepDispatcher` écrit, `StepRunConsumer` relit. C'est le SEUL fil qui relie le
  # pod à son issue. Les négatifs ne sont pas théoriques : ils sont ce que le format produit si
  # une forge (ou un stub) renvoie un `issue["number"]` aberrant — le parseur doit rendre
  # exactement ce que le composeur a écrit, ou rendre `:error`, jamais un AUTRE entier.
  property "P1 ROUND-TRIP — parse(compose(n)) == {:ok, n} pour TOUT entier (négatifs inclus)" do
    check all(n <- integer()) do
      assert {:ok, ^n} = IssueId.parse(IssueId.compose(n))
    end
  end

  # ── P2 — REJET (comportement RÉEL figé) ──

  # INVARIANT : `parse/1` accepte une string SSI elle matche `#{inspect(@accepted)}` — tout le
  # reste rend `:error`. Le préfixe doit être exactement `issue-`, le suffixe doit être un entier
  # COMPLET (pas de queue résiduelle : `"issue-7x"`, `"issue-7 "`, `"issue-"` → `:error`).
  # POURQUOI : un `issue_id` mal formé qui parserait quand même corrélerait le pod à la MAUVAISE
  # issue — le résultat d'un step serait posté sur l'issue d'un autre. Le fail-closed (`:error`)
  # est la seule sortie sûre.
  #
  # ⚠ NOTE D'AUDIT (lot 8) — ÉCART @doc / comportement, figé ici tel qu'il est, NON corrigé :
  # le `@doc` de `parse/1` promet un « STRICT inverse of compose/1 ». Ce n'est pas le cas.
  # `Integer.parse/1` accepte les zéros de tête et le signe explicite :
  #     parse("issue-007") == {:ok, 7}   et   compose(7) == "issue-7"   ≠ "issue-007"
  #     parse("issue-+7")  == {:ok, 7}   et   compose(7) == "issue-7"   ≠ "issue-+7"
  # `parse ∘ compose == id` tient (P1), mais `compose ∘ parse ≠ id` : plusieurs issue_id
  # DISTINCTS désignent la même issue. Bénin tant que l'issue_id n'est qu'un corrélateur lu ;
  # dangereux le jour où il sert de CLÉ (dedup, mutex, lookup) — deux clés pour une issue.
  property "P2 REJET — parse/1 accepte exactement la forme `issue-<entier>`, rien d'autre" do
    check all(s <- candidate_gen(), max_runs: 300) do
      if Regex.match?(@accepted, s) do
        "issue-" <> rest = s
        assert IssueId.parse(s) == {:ok, String.to_integer(rest)}
      else
        assert IssueId.parse(s) == :error,
               "parse(#{inspect(s)}) devrait être :error (hors forme canonique)"
      end
    end
  end

  # INVARIANT : `parse/1` est TOTAL sur les non-strings → `:error`, jamais un FunctionClauseError.
  # POURQUOI : `parse_issue_number` du StepRunConsumer délègue ici sur un champ de payload venu
  # du bus — un `nil`/entier/map y arrive sans cérémonie.
  property "totalité — un terme non-string rend :error (jamais de raise)" do
    check all(
            term <-
              one_of([constant(nil), integer(), boolean(), atom(:alphanumeric), list_of(integer())])
          ) do
      assert IssueId.parse(term) == :error
    end
  end

  # Candidats : formes canoniques, quasi-canoniques (les pièges du parseur), et bruit printable.
  defp candidate_gen do
    one_of([
      map(integer(), &IssueId.compose/1),
      map(string(:printable, max_length: 12), &("issue-" <> &1)),
      string(:printable, max_length: 16),
      member_of([
        "issue-007",
        "issue-+7",
        "issue--7",
        "issue-",
        "issue-7x",
        "issue-7 ",
        "issue- 7",
        "issue-0x10",
        "issue-7_0",
        "issue-١٢",
        "ISSUE-7",
        "issue-7\n",
        "\nissue-7",
        "xissue-7",
        "issue-issue-7",
        "owner/repo#7",
        "nope",
        ""
      ])
    ])
  end
end

defmodule Fleet.Workflow.Gates.PredicatePropertyTest do
  @moduledoc """
  Preuve property-based de l'évaluateur de règles de gate. `gates_predicate_test.exs`
  prouve la totalité sur les TYPES (rule non-string, outputs non-map → false) ; il ne prouve
  RIEN sur le CONTENU — une rule string malformée reste un chemin non couvert, et c'est là que
  vit le risque.

  Pourquoi la totalité de contenu compte : `Gates` applique `eval?` à chaque item de `rules`
  depuis `Fleet.Workflow.StepRunConsumer`, un SINGLETON. Une exception levée ici (regex,
  arithmétique, protocole) ne fait pas « échouer le gate » : elle TUE le consumer, et tout le
  pipeline de steps s'arrête. Le contrat est donc : `rule_string × outputs → boolean()`, TOTAL,
  fail-closed — jamais un raise, jamais un pass sur une preuve absente.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.Workflow.Gates.Predicate

  # Les opérateurs du @ops de Predicate — la grammaire supportée, verrouillée ici.
  @ops ~w(>= <= == != > <)

  # ── générateurs ──

  # Identifiant : charset `\w` (celui du parseur `^(\w+)\s*…`).
  defp identifier, do: string([?a..?z, ?_], min_length: 1, max_length: 8)

  # Operand tel que le parseur le voit : entier, flottant, ou bareword (string).
  defp operand do
    one_of([
      map(integer(), &to_string/1),
      map(float(), &to_string/1),
      string([?a..?z], min_length: 1, max_length: 8)
    ])
  end

  # Terme BIEN FORMÉ : comparaison ou atome nu.
  defp well_formed_term do
    one_of([
      gen all(id <- identifier(), op <- member_of(@ops), rhs <- operand()) do
        "#{id} #{op} #{rhs}"
      end,
      identifier()
    ])
  end

  # Règle bien formée : conjonction de termes en `AND`.
  defp well_formed_rule do
    map(list_of(well_formed_term(), min_length: 1, max_length: 4), &Enum.join(&1, " AND "))
  end

  # Une règle telle qu'elle peut RÉELLEMENT arriver : bien formée, ou du bruit printable
  # (workflow_map bricolé, opérateur inconnu, RHS multi-mots, `AND` pendouillant…).
  defp any_rule do
    one_of([
      well_formed_rule(),
      string(:printable, max_length: 40),
      member_of([
        "",
        "AND",
        " AND ",
        "x AND",
        "AND x",
        "x >=",
        ">= 3",
        "x >>= 3",
        "x == ",
        "x != very critical",
        "x >= NaN",
        "x >= 1e999",
        "x >= 0x10",
        "x >= --3",
        "1 >= x",
        "x.y >= 3",
        "x >= 3 AND AND y",
        "  ",
        "x\n>= 3"
      ])
    ])
  end

  # `outputs` adversarial : clés présentes/absentes, valeurs de tous les types que le pod
  # peut self-reporter (et `nil`, le piège documenté de `!=`).
  defp outputs_gen do
    map_of(
      one_of([identifier(), string(:printable, max_length: 6)]),
      one_of([boolean(), integer(), float(), string(:printable, max_length: 6), constant(nil)]),
      max_length: 6
    )
  end

  # ── P1 — TOTALITÉ DE CONTENU ──

  # INVARIANT : pour TOUTE rule string (bien formée OU bruit printable) et TOUT outputs (clés
  # absentes, valeurs de type quelconque, nil), `eval?/2` rend un booléen et ne lève JAMAIS.
  # POURQUOI : `eval?` tourne dans le StepRunConsumer, un singleton. Un raise n'est pas un gate
  # qui échoue — c'est le consumer qui MEURT et le pipeline de steps entier qui s'arrête. La
  # totalité n'est prouvée aujourd'hui que sur les TYPES (rule non-string) ; ici on la prouve
  # sur le CONTENU, qui est le vrai domaine d'entrée.
  property "P1 TOTALITÉ — toute rule string × tout outputs → boolean(), jamais de raise" do
    check all(rule <- any_rule(), outputs <- outputs_gen(), max_runs: 400) do
      assert is_boolean(Predicate.eval?(rule, outputs)),
             "eval?(#{inspect(rule)}, #{inspect(outputs)}) doit rendre un booléen"
    end
  end

  # ── P2 — FAIL-CLOSED ──

  # INVARIANT : pour CHAQUE opérateur supporté, un identifiant ABSENT des outputs → false.
  # Idem pour la forme atome (identifiant nu).
  # POURQUOI : c'est la règle cardinale du gate — « pas de pass sur une preuve absente ». Un
  # `!=` est le piège concret : `nil != "critical"` vaut `true` en Elixir nu, donc un fait NON
  # RAPPORTÉ par le pod validerait le gate `severity_max != critical` et laisserait passer du
  # code jamais audité. La property couvre les 6 opérateurs, pas seulement celui qu'on a en tête.
  property "P2 FAIL-CLOSED — identifiant absent des outputs → false, pour TOUT opérateur" do
    check all(
            outputs <- outputs_gen(),
            id <- identifier(),
            op <- member_of(@ops),
            rhs <- operand()
          ) do
      absent = Map.delete(outputs, id)

      refute Predicate.eval?("#{id} #{op} #{rhs}", absent),
             "fait absent + `#{op}` doit être fail-closed"

      refute Predicate.eval?(id, absent), "atome absent doit être fail-closed"

      # Le fait PRÉSENT-À-NIL est traité comme absent (nil ≡ absent) — même exigence.
      refute Predicate.eval?("#{id} #{op} #{rhs}", Map.put(absent, id, nil))
      refute Predicate.eval?(id, Map.put(absent, id, nil))
    end
  end

  # ── Oracle : la comparaison numérique fait bien ce qu'elle dit ──

  # INVARIANT : sur deux entiers, `eval?("id OP n", %{id => m})` == `m OP n` en Elixir natif.
  # POURQUOI : la totalité fail-closed pourrait être obtenue TRIVIALEMENT par un `false`
  # constant — ce test-là passerait. L'oracle prouve que le fail-closed n'a pas mangé le
  # comportement UTILE : un gate `tasks_count >= 1` doit encore savoir dire `true`.
  property "oracle — comparaison entière : eval? ≡ l'opérateur Elixir (les 6 ops, négatifs inclus)" do
    check all(id <- identifier(), m <- integer(), n <- integer(), op <- member_of(@ops)) do
      expected =
        case op do
          ">=" -> m >= n
          "<=" -> m <= n
          ">" -> m > n
          "<" -> m < n
          "==" -> m == n
          "!=" -> m != n
        end

      assert Predicate.eval?("#{id} #{op} #{n}", %{id => m}) == expected,
             "eval?(#{inspect("#{id} #{op} #{n}")}, %{#{inspect(id)} => #{m}}) ≠ #{m} #{op} #{n}"
    end
  end

  # INVARIANT : `AND` est la conjonction booléenne exacte des termes — évaluer la règle
  # composée == évaluer chaque terme et les `and`.
  # POURQUOI : un `AND` qui court-circuiterait mal (ou qui avalerait un terme non parsé)
  # rendrait un gate à 3 règles VERT alors qu'un seul de ses termes tient. C'est la
  # composition qui est load-bearing, pas seulement chaque terme isolé.
  property "AND — la conjonction est exacte (aucun terme avalé)" do
    check all(
            terms <- list_of(well_formed_term(), min_length: 2, max_length: 4),
            outputs <- outputs_gen()
          ) do
      expected = Enum.all?(terms, &Predicate.eval?(&1, outputs))
      assert Predicate.eval?(Enum.join(terms, " AND "), outputs) == expected
    end
  end
end

defmodule Fleet.FindingsWireTest do
  use ExUnit.Case, async: true

  alias Fleet.FindingsWire

  defp findings, do: %{"findings" => [%{"severity" => "minor", "category" => "tests"}]}

  describe "aller-retour" do
    test "ce qui est rendu se relit à l'identique" do
      body = "Prose du juge.\n\nDeuxième paragraphe." <> FindingsWire.render(findings())

      assert {:ok, findings()} == FindingsWire.parse(body)
    end

    test "le JSON survit aux caractères qui cassent une regex naïve" do
      # Le motif est du texte arbitraire écrit par un agent : accolades, guillemets, backticks et
      # sauts de ligne DANS les valeurs. C'est la raison pour laquelle `last_block/1` découpe au
      # lieu de matcher.
      f = %{
        "findings" => [
          %{"description" => "le test contient ```json et {\"une\": \"accolade\"}\net un saut"}
        ]
      }

      assert {:ok, ^f} = FindingsWire.parse("prose" <> FindingsWire.render(f))
    end

    test "un juge sans verdict machine poste EXACTEMENT le corps d'aujourd'hui" do
      # La compat byte-for-byte est le contrat de C1 comme de C2 : un juge legacy ne doit pas voir
      # sa review changer d'un octet parce que le fil existe.
      assert FindingsWire.render(nil) == ""
    end
  end

  describe "absence vs cassé — deux faits différents" do
    test "aucun bloc → :none (ce n'est pas une erreur)" do
      assert :none == FindingsWire.parse("Le juge a écrit de la prose, et rien d'autre.")
    end

    test "corps vide ou nil → :none" do
      assert :none == FindingsWire.parse("")
      assert :none == FindingsWire.parse(nil)
    end

    test "bloc présent mais JSON cassé → {:error, :undecodable}, jamais :none" do
      # Une main humaine peut éditer un corps de review sur la forge. « personne n'a écrit » et
      # « quelqu'un a écrit et c'est cassé » n'accusent pas la même chose — seul le second accuse.
      body =
        "prose\n\n#{FindingsWire.marker()}\n```json\n{\"findings\": [ceci n'est pas du JSON}\n```"

      assert {:error, :undecodable} == FindingsWire.parse(body)
    end

    test "marqueur sans bloc fermé → :none (rien à lire, rien à accuser)" do
      assert :none == FindingsWire.parse("prose #{FindingsWire.marker()} mais pas de bloc")
    end

    test "un JSON qui décode en NON-objet est refusé" do
      body = "#{FindingsWire.marker()}\n```json\n[1, 2, 3]\n```"
      assert {:error, :undecodable} == FindingsWire.parse(body)
    end
  end

  describe "le juge ne peut pas masquer le bloc du système" do
    test "un marqueur cité dans la prose du juge ne gagne pas contre celui d'en bas" do
      # Le système appende TOUJOURS après la prose : c'est pourquoi le DERNIER marqueur gagne.
      # Sans cette règle, un juge qui cite le format (ou le recopie de travers) détournerait la
      # lecture du gate vers son propre texte.
      leurre = "#{FindingsWire.marker()}\n```json\n{\"findings\": [\"leurre\"]}\n```"
      body = "Le juge explique le format :\n\n" <> leurre <> FindingsWire.render(findings())

      assert {:ok, findings()} == FindingsWire.parse(body)
    end
  end

  describe "F-3 — le corps est ÉDITABLE, et le parseur ne doit pas dépendre du contraire" do
    test "une main qui répond avec un bloc de code APRÈS le nôtre ne casse plus la lecture" do
      # LE CAS MESURÉ (2026-08-19). La règle « notre barrière est la dernière » était vraie au
      # rendu et fausse dès qu'un humain répondait dans le même corps sur la forge. Un ```bash
      # ajouté rendait `{:error, :undecodable}` — et un cran plus haut, ça EFFAÇAIT le blocage
      # d'une carte au lieu de le lever : une zone grise qui devait un arbitrage était scellée
      # `:approved`.
      charge = %{"findings" => [%{"severity" => "critical", "category" => "tests"}]}

      corps =
        "AVIS FAVORABLE\n" <>
          FindingsWire.render(charge) <>
          "\n\nvu, je corrige :\n\n```bash\nmix test --only tests\n```\n"

      assert {:ok, ^charge} = FindingsWire.parse(corps)
    end

    test "et le cas qui avait motivé « la dernière barrière » tient toujours" do
      # Un finding CITE DU CODE — c'est sa forme normale. Les deux contraintes sont désormais
      # satisfaites par la même règle : décoder, du plus long au plus court.
      charge = %{"findings" => [%{"detail" => "le test fait\n```\nassert true\n```\net rien"}]}

      assert {:ok, ^charge} = FindingsWire.parse("prose\n" <> FindingsWire.render(charge))
    end

    test "les deux à la fois : citation interne ET réponse humaine après" do
      charge = %{"findings" => [%{"severity" => "minor", "detail" => "cf ```mix gate```"}]}

      corps =
        FindingsWire.render(charge) <> "\n\nok\n\n```elixir\nassert false\n```\n"

      assert {:ok, ^charge} = FindingsWire.parse(corps)
    end
  end

  describe "F-3 — « illisible » n'est pas « absent », et ne s'échange pas contre un feu vert" do
    test "une charge illisible BLOQUE dès qu'un plancher est déclaré" do
      # L'honnêteté du modèle tient à ça : la réponse à « y a-t-il un finding au-dessus de la
      # ligne ? » est INCONNUE, et inconnu ne se dépense pas comme non.
      assert FindingsWire.blocks?(FindingsWire.unreadable(), "critical")
      assert FindingsWire.blocks?(FindingsWire.unreadable(), "minor")
    end

    test "sans plancher déclaré, elle ne bloque rien — la dégénérescence est intacte" do
      # La condition qui autorise les cartes sans courbe à ne rien changer : pas de plancher, pas
      # de question posée, donc pas de réponse inventée.
      refute FindingsWire.blocks?(FindingsWire.unreadable(), nil)
    end

    test "ce n'est PAS un finding fabriqué" do
      # Inventer un `critical` que personne n'a mesuré ferait entrer un défaut imaginaire dans le
      # dossier — et le premier lecteur à le citer aurait raison de le croire.
      assert FindingsWire.unreadable() == %{"findings_unreadable" => true}
      refute Map.has_key?(FindingsWire.unreadable(), "findings")
    end
  end
end

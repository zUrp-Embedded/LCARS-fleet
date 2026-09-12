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
      # Findings can contain JSON punctuation, fences and newlines inside their string values.
      f = %{
        "findings" => [
          %{"description" => "le test contient ```json et {\"une\": \"accolade\"}\net un saut"}
        ]
      }

      assert {:ok, ^f} = FindingsWire.parse("prose" <> FindingsWire.render(f))
    end

    test "un juge sans verdict machine poste EXACTEMENT le corps d'aujourd'hui" do
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
      # The appended system block must win over a marker quoted earlier in judge prose.
      leurre = "#{FindingsWire.marker()}\n```json\n{\"findings\": [\"leurre\"]}\n```"
      body = "Le juge explique le format :\n\n" <> leurre <> FindingsWire.render(findings())

      assert {:ok, findings()} == FindingsWire.parse(body)
    end
  end

  describe "F-3 — le corps est ÉDITABLE, et le parseur ne doit pas dépendre du contraire" do
    test "une main qui répond avec un bloc de code APRÈS le nôtre ne casse plus la lecture" do
      # Review bodies remain editable; an appended code block must not hide a critical finding.
      charge = %{"findings" => [%{"severity" => "critical", "category" => "tests"}]}

      corps =
        "AVIS FAVORABLE\n" <>
          FindingsWire.render(charge) <>
          "\n\nvu, je corrige :\n\n```bash\nmix test --only tests\n```\n"

      assert {:ok, ^charge} = FindingsWire.parse(corps)
    end

    test "et le cas qui avait motivé « la dernière barrière » tient toujours" do
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
      assert FindingsWire.blocks?(FindingsWire.unreadable(), "critical")
      assert FindingsWire.blocks?(FindingsWire.unreadable(), "minor")
    end

    test "sans plancher déclaré, elle ne bloque rien — la dégénérescence est intacte" do
      refute FindingsWire.blocks?(FindingsWire.unreadable(), nil)
    end

    test "ce n'est PAS un finding fabriqué" do
      # Represent unreadability without recording an invented defect.
      assert FindingsWire.unreadable() == %{"findings_unreadable" => true}
      refute Map.has_key?(FindingsWire.unreadable(), "findings")
    end
  end
end

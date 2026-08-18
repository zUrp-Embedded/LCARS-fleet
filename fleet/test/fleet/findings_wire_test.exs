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
end

defmodule Fleet.Forge.PayloadTest do
  @moduledoc """
  Lecteurs confrontes aux fichiers de test/fixtures/forge/ (Gitea 1.26.1-rootless,
  provenance dans leur README), sans serveur en direct. Les valeurs attendues independantes
  de Payload.paths evitent de seulement recopier les chemins du lecteur dans le test.
  """
  use ExUnit.Case, async: true

  alias Fleet.Forge.Payload

  @dir Path.join([__DIR__, "..", "..", "fixtures", "forge"])

  defp charge(nom), do: @dir |> Path.join("#{nom}.json") |> File.read!() |> Jason.decode!()

  describe "les chemins declares atteignent la charge REELLE" do
    test "sur une PR : tout ce qu'une PR porte est atteint" do
      pr = charge("pr")

      assert Payload.number(pr) == 2
      assert Payload.state(pr) == "open"
      assert Payload.title(pr) == "une PR de mesure"
      assert Payload.body(pr) == "corps"
      assert Payload.head_ref(pr) == "lcars/issue-1-engineer"
      assert is_binary(Payload.head_sha(pr)) and byte_size(Payload.head_sha(pr)) == 40
      assert Payload.base_ref(pr) == "main"
      assert Payload.merged?(pr) == false
      assert Payload.mergeable(pr) == true
      assert Payload.author_login(pr) == "mesure"
    end

    test "sur une issue : et l'ASYMETRIE avec la PR est mesuree, pas supposee" do
      issue = charge("issue")

      assert Payload.number(issue) == 1
      assert Payload.state(issue) == "open"
      assert Payload.author_login(issue) == "mesure"

      # Asymetrie des captures : repository sur l'issue, head/base sur la PR.
      assert Payload.repository_full_name(issue) == "mesure/capture"
      assert Payload.repository_full_name(charge("pr")) == nil

      assert Payload.head_ref(issue) == nil
      assert Payload.base_ref(issue) == nil
    end

    test "un champ NULL de la forge devient `nil`, jamais une exception" do
      # La PR capturee n'a ni assigne ni label ; l'issue a les deux.
      assert Payload.assignee_login(charge("pr")) == nil
      assert Payload.label_names(charge("pr")) == []

      assert Payload.assignee_login(charge("issue")) == "mesure"
      assert Payload.label_names(charge("issue")) == ["lcars-in-flight"]
    end

    test "une charge vide ne fait lever aucun lecteur — la forge ne garantit rien" do
      for {fait, _chemin} <- Payload.paths() do
        assert Payload.get(%{}, fait) == nil
      end

      assert Payload.merged?(%{}) == false
      assert Payload.label_names(%{}) == []
    end
  end

  describe "le garde du garde" do
    test "chaque fait declare a un lecteur, et chaque lecteur porte sur la capture" do
      # Controle les noms exportes, pas leur arite ni leur lecture effective de chaque capture.
      faits = Map.keys(Payload.paths())
      assert length(faits) >= 12, "la table des chemins a retreci : #{length(faits)}"

      exportees =
        Payload.__info__(:functions) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      # Meme nom que le fait, avec ? accepte pour les predicats.
      sans_lecteur =
        Enum.reject(faits, fn f ->
          MapSet.member?(exportees, f) or MapSet.member?(exportees, :"#{f}?")
        end)

      assert sans_lecteur == [],
             "faits declares dans @paths sans lecteur public : #{inspect(sans_lecteur)}"
    end
  end
end

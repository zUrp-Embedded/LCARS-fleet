defmodule Fleet.Forge.PayloadTest do
  @moduledoc """
  Le collage entre les chemins declares et ce que la forge envoie VRAIMENT.

  `Fleet.Forge.Payload` declare un chemin par fait. Rien, dans une relecture, ne dit qu'un chemin
  correspond encore a l'API : c'est exactement la panne que ce depot traque ailleurs — une
  affirmation vraie le jour ou elle a ete ecrite.

  ⚠ CE TEMOIN NE FABRIQUE AUCUNE CHARGE. Il lit `test/fixtures/forge/`, capture d'une forge REELLE
  (`gitea/gitea:1.26.1-rootless`, digest verifie sur le conteneur, cf. le README de la capture).
  Un temoin qui construirait sa propre charge prouverait seulement que je sais recopier mes propres
  chemins.
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

      # `repository.full_name` existe sur une ISSUE...
      assert Payload.repository_full_name(issue) == "mesure/capture"
      # ...et PAS sur une PR. Le lecteur rend `nil`, il ne leve pas.
      assert Payload.repository_full_name(charge("pr")) == nil

      # `head`/`base` sont l'inverse : une issue n'en a pas.
      assert Payload.head_ref(issue) == nil
      assert Payload.base_ref(issue) == nil
    end

    test "un champ NULL de la forge devient `nil`, jamais une exception" do
      # ⚠ MESURE : `assignee` vaut `null` sur les deux charges quand personne n'est assigne, et la
      # specification OpenAPI de cette version ne declare AUCUN champ requis. Un acces non garde
      # (`payload["assignee"]["login"]`) casserait ici.
      for nom <- ~w(pr issue) do
        assert Payload.assignee_login(charge(nom)) == nil
        assert Payload.label_names(charge(nom)) == []
      end
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
      # Sans ce parcours, ajouter une entree a `@paths` sans son lecteur passerait inapercu — et le
      # temoin ci-dessus resterait vert en couvrant un fait de moins.
      faits = Map.keys(Payload.paths())
      assert length(faits) >= 12, "la table des chemins a retreci : #{length(faits)}"

      exportees =
        Payload.__info__(:functions) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      # Le FAIT se nomme par ce qu'on obtient, pas par la clef du fil : `label_names` et non
      # `labels`, `assignee_logins` et non `assignees`. Le lecteur porte donc le meme nom, et la
      # seule tolerance est le `?` d'un predicat. Un cas particulier par fait rendrait ce garde
      # complice de la derive qu'il surveille.
      sans_lecteur =
        Enum.reject(faits, fn f ->
          MapSet.member?(exportees, f) or MapSet.member?(exportees, :"#{f}?")
        end)

      assert sans_lecteur == [],
             "faits declares dans @paths sans lecteur public : #{inspect(sans_lecteur)}"
    end
  end
end

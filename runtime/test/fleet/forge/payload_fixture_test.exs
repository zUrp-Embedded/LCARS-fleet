defmodule Fleet.Forge.PayloadFixtureTest do
  @moduledoc """
  Fabrique et lecteur partagent Payload.paths : un aller-retour seul laissait passer
  une mutation du chemin base_ref. La resolution sur captures apporte un controle independant,
  sans detecter tout mauvais chemin qui pointerait vers un autre champ non nil.
  Les projections label_names/assignee_logins gardent un aller-retour car leurs clauses
  d'ecriture reconstruisent les objets lus.
  """
  use ExUnit.Case, async: true

  alias Fleet.Forge.Payload
  alias Fleet.Forge.PayloadFixture

  # Une valeur plausible par fait, dans la forme que le LECTEUR rend.
  @valeurs %{
    number: 4242,
    state: "closed",
    title: "un titre",
    body: "un corps",
    merged: true,
    mergeable: false,
    head_ref: "lcars/issue-7-engineer",
    head_sha: String.duplicate("a", 40),
    base_ref: "main",
    label_names: ["lcars-in-flight", "stage/review"],
    assignee_login: "qualifier",
    author_login: "engineer",
    repository_full_name: "org/repo",
    full_name: "org/repo",
    default_branch: "trunk",
    assignee_logins: ["scribe", "vulcan"]
  }

  describe "un fait ENONCE est le fait EFFECTIF" do
    # Delegation lit la liste avant le singulier : la surcharge doit remplacer aussi la liste
    # capturee, sauf si le test en fournit une explicitement.
    test "`assignee_login` pose AUSSI la liste — sinon la capture la recouvre en silence" do
      charge = PayloadFixture.issue(assignee_login: "l")

      assert Payload.assignee_login(charge) == "l"
      assert Payload.assignee_logins(charge) == ["l"]
    end

    test "un `assignee_logins` EXPLICITE gagne — un fait nomme n'est jamais derive" do
      charge = PayloadFixture.issue(assignee_login: "l", assignee_logins: ["a", "b"])

      assert Payload.assignee_login(charge) == "l"
      assert Payload.assignee_logins(charge) == ["a", "b"]
    end
  end

  describe "chaque chemin declare RESOUT sur la capture reelle" do
    # PR, issue et depot couvrent des champs differents ; un nouveau fait demande une capture.
    for fait <- Map.keys(Payload.paths()) do
      @fait fait
      test "#{fait}" do
        # Tester != nil garde false (merged sur la PR) ; une affectation-filtre l'ecarterait.
        vus =
          for forme <- [:pull, :issue, :repo],
              Payload.get(PayloadFixture.raw(forme), @fait) != nil,
              do: forme

        assert vus != [],
               "le chemin declare pour #{inspect(@fait)} ne resout sur AUCUNE capture reelle"
      end
    end
  end

  describe "aller-retour des faits PROJETES (le seul qui puisse diverger)" do
    for fait <- [:label_names, :assignee_logins] do
      @fait fait
      test "#{fait}" do
        valeur = Map.fetch!(@valeurs, @fait)
        charge = PayloadFixture.pull([{@fait, valeur}])

        assert apply(Payload, @fait, [charge]) == valeur,
               "l'ecriture et la lecture de #{inspect(@fait)} ne reconstruisent pas la meme forme"
      end
    end
  end

  describe "la charge de base est REELLE, pas inventee" do
    test "sans surcharge, la fabrique rend la capture telle quelle" do
      assert PayloadFixture.pull() == PayloadFixture.raw(:pull)
      assert PayloadFixture.issue() == PayloadFixture.raw(:issue)
    end

    test "les champs NON surcharges gardent leur valeur reelle" do
      charge = PayloadFixture.pull(merged: true)

      # Verifie ici la conservation de head_sha/base_ref, pas de chaque champ de la capture.
      assert Payload.head_sha(charge) == Payload.head_sha(PayloadFixture.raw(:pull))
      assert Payload.base_ref(charge) == Payload.base_ref(PayloadFixture.raw(:pull))
      assert Payload.merged?(charge) == true
    end

    test "un fait qui n'est pas declare est REFUSE, pas ecrit en clef brute" do
      assert_raise ArgumentError, ~r/not a declared fact/, fn ->
        PayloadFixture.pull(milestone_title: "x")
      end
    end
  end
end

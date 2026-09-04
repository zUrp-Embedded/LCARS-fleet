defmodule Fleet.Forge.PayloadFixtureTest do
  @moduledoc """
  Le collage entre la fabrique et le lecteur.

  ⚠ L'ALLER-RETOUR SEUL EST UNE TAUTOLOGIE, ET LA PREMIERE VERSION DE CE TEMOIN NE L'ETAIT QUE CA.
  `PayloadFixture` ecrit par `Payload.paths/0` et `Payload` lit par la meme table : changer un
  chemin deplace les DEUX ensemble, et l'aller-retour reste vert. Mutation jouee — `base_ref`
  pointe sur une autre clef, zero echec. Un temoin qui ne peut pas rougir n'achete rien.

  Ce qui mord, et qui est le vrai garde : **chaque chemin declare doit RESOUDRE sur la capture
  reelle**. Un chemin qui derive de l'API n'a plus de valeur nulle part, et ca, aucune table
  partagee ne peut le masquer.

  L'aller-retour est conserve pour les faits dont la lecture est une PROJECTION — `label_names`,
  `assignee_logins` : l'ecriture y reconstruit des objets par des clauses propres, donc les deux
  cotes peuvent vraiment diverger.
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
    # Le runtime lit `assignee_logins` D'ABORD (`Delegation.Issues.issue_assignee/1`), avec
    # `assignee_login` en repli. La capture reelle porte `assignees: ["mesure"]` : sans ce
    # miroir, un temoin qui ecrit `assignee_login: "l"` obtient un objet dont l'assigne effectif
    # reste "mesure". La fabrique disait une chose et l'objet en portait une autre.
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
    # Le garde qui mord. Une capture par forme : la PR porte `head`/`base`/`merged`, l'issue porte
    # `repository` et son assigne, le depot porte `full_name`/`default_branch`. Un fait qui ne
    # resout nulle part est un chemin qui a derive de l'API — ou un fait qu'aucune capture ne
    # couvre, ce qui se corrige en capturant, pas en relachant l'assertion.
    for fait <- Map.keys(Payload.paths()) do
      @fait fait
      test "#{fait}" do
        # ⚠ PAS `v = Payload.get(...)` EN FILTRE : dans un `for`, une affectation vaut filtre, et
        # `merged` vaut `false` sur une PR ouverte — un fait resolu et pourtant ecarte. « absent »
        # et « faux » sont deux reponses.
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

      # ⚠ CE QUI FAIT TOUT L'INTERET : un temoin qui n'enonce qu'un fait recoit quand meme la forme
      # COMPLETE. C'est ce qui empeche un garde lisant un autre champ de retomber sur son repli.
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

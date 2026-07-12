defmodule Fleet.Pilot.ProjectOnboardTest do
  @moduledoc """
  F-C084 — `onboard/2` CRÉE un projet frais : il scaffolde `main` + push par-dessus. Un repo PRÉ-EXISTANT
  n'est PAS une cible sûre (clobber du `main` d'un vrai repo : celui d'un humain onboardé par erreur, ou un
  projet complet ré-onboardé). La décision PURE `classify_create_repo/3` fail-loud sur `{:ok, :already_exists}`
  (create_repo 409) ; seul un CREATE génuine procède. `create_repo` est en TÊTE du `with` d'onboard (avant
  clone/scaffold/push) → l'erreur court-circuite la séquence par construction : rien n'est écrit sur le repo
  existant. (L'adoption d'un repo existant passe par `import/2`, qui NE scaffolde PAS `main`.)
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.ProjectOnboard

  describe "classify_create_repo/3 (F-C084 — pré-existant ≠ cible d'onboard)" do
    test "CREATE génuine ({:ok, full_name}) → {:ok, full_name} (onboard possède le repo frais)" do
      assert {:ok, "fleet/neuf"} =
               ProjectOnboard.classify_create_repo({:ok, "fleet/neuf"}, "fleet", "neuf")
    end

    test "repo DÉJÀ existant (409 → {:ok, :already_exists}) → {:error, {:repo_already_exists, _}} (FAIL-LOUD)" do
      # Le cœur du finding : avant, already_exists → {:ok, \"fleet/deja\"} = SUCCÈS → onboard clonait +
      # scaffoldait + poussait sur le `main` existant = CLOBBER silencieux. Désormais fail-loud → l'opérateur
      # utilise import_project (adopte, contenu intact) ou supprime le repo stale/partiel.
      assert {:error, {:repo_already_exists, "fleet/deja"}} =
               ProjectOnboard.classify_create_repo({:ok, :already_exists}, "fleet", "deja")
    end

    test "erreur forge propagée telle quelle (pas d'interprétation)" do
      assert {:error, {:http, 500, "boom"}} =
               ProjectOnboard.classify_create_repo({:error, {:http, 500, "boom"}}, "fleet", "x")
    end
  end
end

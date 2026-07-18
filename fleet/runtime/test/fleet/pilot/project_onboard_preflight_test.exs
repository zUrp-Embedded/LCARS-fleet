defmodule Fleet.Pilot.ProjectOnboardPreflightTest do
  @moduledoc """
  F2 (Z7c migration — débrief architecte 2026-07-12) : preflight `ensure_human_provisioned`
  AVANT toute création. Contrats testés : absence PROUVÉE de compte/team → erreur avec les
  gestes admin EXACTS ; forge en PANNE → :forge_preflight_failed SANS instructions (on
  n'envoie jamais l'opérateur créer un compte sur une panne) ; humain provisionné → le
  preflight est transparent (la séquence continue). Seam :forge_users — aucun réseau.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Fleet.Pilot.ProjectOnboard

  defmodule OkUsers do
    def user_exists?(_u, _fc), do: {:ok, true}
    def team_member?(_org, "humans", _u, _fc), do: {:ok, true}
  end

  defmodule NoAccountUsers do
    def user_exists?(_u, _fc), do: {:ok, false}
    def team_member?(_org, _t, _u, _fc), do: raise("ne doit pas être atteint")
  end

  defmodule NoTeamUsers do
    def user_exists?(_u, _fc), do: {:ok, true}
    def team_member?(_org, "humans", _u, _fc), do: {:ok, false}
  end

  defmodule DownForge do
    def user_exists?(_u, _fc), do: {:error, {:transport, :econnrefused}}
    def team_member?(_org, _t, _u, _fc), do: {:error, {:transport, :econnrefused}}
  end

  defmodule ForbiddenTeamUsers do
    # Compte OK, mais le token runtime ne peut PAS lire l'appartenance team (403) : cas réel
    # forge — le compte de service est un simple membre d'org (ni owner, ni membre de `humans`),
    # Gitea refuse GET /teams/<id>/members/<u>. « Ne peut pas vérifier » ≠ « humain absent ».
    def user_exists?(_u, _fc), do: {:ok, true}

    def team_member?(_org, "humans", _u, _fc),
      do: {:error, {:http, 403, %{"message" => "Forbidden"}}}
  end

  defp opts(tmp, users),
    do: [
      human: "ghost-human",
      forge_users: users,
      projects_root: Path.join(tmp, "projects"),
      work_root: Path.join(tmp, "work")
    ]

  @tag :tmp_dir
  test "compte forge absent → human_not_provisioned + gestes admin exacts (compte)", %{
    tmp_dir: tmp
  } do
    assert {:error, {:human_not_provisioned, "ghost-human", gestures}} =
             ProjectOnboard.onboard("poc-f2", opts(tmp, NoAccountUsers))

    assert gestures =~ "admin/users"
    assert gestures =~ "ghost-human"
    # rien n'a été créé : le preflight court AVANT tout mkdir/clone
    refute File.exists?(Path.join([tmp, "projects", "poc-f2"]))
  end

  @tag :tmp_dir
  test "compte présent mais hors team humans → gestes admin exacts (team)", %{tmp_dir: tmp} do
    assert {:error, {:human_not_provisioned, "ghost-human", gestures}} =
             ProjectOnboard.onboard("poc-f2", opts(tmp, NoTeamUsers))

    assert gestures =~ "teams"
    assert gestures =~ "humans"
  end

  @tag :tmp_dir
  test "forge en PANNE → forge_preflight_failed, JAMAIS d'instructions de création", %{
    tmp_dir: tmp
  } do
    assert {:error, {:forge_preflight_failed, {:transport, :econnrefused}}} =
             ProjectOnboard.onboard("poc-f2", opts(tmp, DownForge))
  end

  @tag :tmp_dir
  test "humain provisionné → preflight transparent (la séquence continue jusqu'au conflit suivant)",
       %{tmp_dir: tmp} do
    o = opts(tmp, OkUsers)
    proj = Path.join([tmp, "projects", "poc-f2"])
    File.mkdir_p!(proj)

    # le preflight PASSE (sinon on aurait human_not_provisioned) ; l'étape suivante
    # (refute_existing) attrape le dossier pré-existant → preuve d'ordre et de passage.
    assert {:error, {:already_exists, ^proj}} = ProjectOnboard.onboard("poc-f2", o)
  end

  @tag :tmp_dir
  test "DR-018 : team NON VÉRIFIABLE (403) → REFUS par défaut (:human_team_unverifiable + gestes), rien créé",
       %{tmp_dir: tmp} do
    # DR-018 : le 4ᵉ état (non-vérifiable) n'est PLUS un :ok muet. Une admission load-bearing non-prouvable
    # ≠ « vérifiée » → refus par défaut, avec les gestes admin exacts (droit de lecture / prouver / dégradé).
    assert {:error, {:human_team_unverifiable, "ghost-human", gestures}} =
             ProjectOnboard.onboard("poc-f2", opts(tmp, ForbiddenTeamUsers))

    assert gestures =~ "NOT VERIFIABLE"
    assert gestures =~ "allow_unverifiable_human_team?"
    # une admission non-prouvable ne crée RIEN (le garde court AVANT tout mkdir/clone)
    refute File.exists?(Path.join([tmp, "projects", "poc-f2"]))
  end

  @tag :tmp_dir
  test "DR-018 : team 403 + allow_unverifiable_human_team?: true → MODE DÉGRADÉ EXPLICITE (procède, warning LOUD)",
       %{tmp_dir: tmp} do
    # Le dégradé RESTE possible (forge où le token n'est pas org-admin) mais comme MODE CONSCIENT opt-in,
    # pas comme succès indistinguable : l'opérateur le pose, la trace est LOUD, create_issue reste le filet.
    o = Keyword.put(opts(tmp, ForbiddenTeamUsers), :allow_unverifiable_human_team?, true)
    proj = Path.join([tmp, "projects", "poc-f2"])
    File.mkdir_p!(proj)

    log =
      capture_log(fn ->
        # dégradé EXPLICITE : le preflight procède malgré le 403 → la séquence continue et attrape le
        # dossier pré-existant (preuve de passage), au lieu de bloquer un humain PROVISIONNÉ sans droit de lecture.
        assert {:error, {:already_exists, ^proj}} = ProjectOnboard.onboard("poc-f2", o)
      end)

    assert log =~ "EXPLICIT DEGRADED MODE"
    assert log =~ "403"
  end

  @tag :tmp_dir
  test "import/2 porte le MÊME preflight", %{tmp_dir: tmp} do
    assert {:error, {:human_not_provisioned, "ghost-human", _}} =
             ProjectOnboard.import("fleet/poc-f2", opts(tmp, NoAccountUsers))
  end
end

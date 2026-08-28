defmodule Fleet.Pilot.MergeAndPromoteWorktreeTest do
  @moduledoc """
  Wiring: `merge_and_promote` TRIGGERS the deliverable projection onto the local clone after a
  successful merge, and NEVER after a failed merge (nothing was merged → nothing to project). The
  `:worktree_sync` seam points to a spy; `merge_and_promote` runs in THIS process (direct call, no
  GenServer) → the spy's `send(self(), …)` does reach the test. async: false (seams are global
  configs, set/restored).
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ForgeStubs.{CloseFailForge, MergeFailForge, OkForge}
  alias Fleet.Pilot.MergeAndPromote
  alias Fleet.TestEnv

  @moduletag :tmp_dir

  defmodule SpySync do
    # Called synchronously from merge_and_promote (same process as the test) → self() = the test.
    def sync(repo, branch), do: send(self(), {:worktree_sync, repo, branch})
  end

  setup %{tmp_dir: tmp} do
    TestEnv.put_env_restoring(:lcars_fleet, :pilot_worktree_sync, SpySync)

    # `merge_and_promote` signs INTERNALLY (les deux jetons de rail → RoleToken) and is FAIL-CLOSED
    # (soft-default #3: no system fallback). We place a resolvable gatekeeper token in a hermetic tmp
    # (never the runner's real `/opt/lcars/var/tokens`) → the seal proceeds; this test verifies the worktree
    # projection, not the token.
    # Les DEUX rails du sceau depuis le 2026-08-20 : `chief` fusionne, `gatekeeper` promeut.
    TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)
    Fleet.TestEnv.put_role_token!("gatekeeper", "tok-gatekeeper")
    Fleet.TestEnv.put_role_token!("chief", "tok-chief")

    :ok
  end

  test "merge OK → projection triggered on the right repo" do
    assert :ok =
             MergeAndPromote.merge_and_promote(OkForge, "fleet/myproj", 7, 42, "engineer", [],
               base_branch: "main"
             )

    assert_received {:worktree_sync, "fleet/myproj", "main"}
  end

  test "merge KO → NO projection (the merge did not happen, nothing to align)" do
    assert {:error, {:merge, _}} =
             MergeAndPromote.merge_and_promote(
               MergeFailForge,
               "fleet/myproj",
               7,
               42,
               "engineer",
               [],
               base_branch: "main"
             )

    refute_received {:worktree_sync, _, _}
  end

  test "soft-default #3 — jeton du rail MERGE absent → refus AVANT toute tentative, rien a projeter" do
    # ⚠ CE TEST S'APPELAIT « gatekeeper token ABSENT → seal REFUSES » ET IL PASSAIT POUR LA MAUVAISE
    # RAISON (revue 2026-08-20). Il vide le repertoire de jetons ENTIER : depuis la separation des
    # rails, c'est le jeton CHIEF qui manque en premier et c'est LUI qui provoque le refus. Le test
    # decrivait donc l'ancien contrat — « sans jeton gatekeeper, le sceau ne fusionne pas » — tout en
    # mesurant autre chose.
    #
    # Fail-closed intact, et c'est ce qu'on epingle ici : sans le jeton du rail merge, AUCUNE
    # tentative, jamais de repli sur le compte systeme ni sur l'autre rail.
    empty = Fleet.TestEnv.tmp_path("no-role-token")
    File.mkdir_p!(empty)
    TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, empty)

    assert {:error, :role_token_unavailable} =
             MergeAndPromote.merge_and_promote(OkForge, "fleet/myproj", 7, 42, "engineer", [],
               base_branch: "main"
             )

    refute_received {:worktree_sync, _, _}
  end

  test "jeton du rail DECISION absent APRES un merge reussi → close_after_merge, et la projection a lieu" do
    # LE CAS QUE LA SEPARATION DES RAILS A CREE, ET QUE RIEN NE COUVRAIT (revue 2026-08-20). Le
    # `@doc` le promet — « or the decision rail had no token » — et aucun test ne le mesurait.
    #
    # LA MUTATION QU'IL TUE : remplacer `as_role(forge_opts, gatekeeper_role())` par `forge_opts`
    # dans `converge_postconditions` ferait partir le commentaire et la fermeture sous le compte
    # SYSTEME — exactement le mensonge d'attribution que ce lot existe pour supprimer — et la suite
    # serait restee verte.
    #
    # Ce qui doit se produire : le merge A LIEU (le rail merge a son jeton), puis la promotion ne
    # peut pas etre signee. Ni commentaire ni fermeture, retour honnete `{:close_after_merge, _}` —
    # et la projection se fait quand meme, parce que la brique EST fusionnee : c'est la forge qui
    # fait foi, pas la ceremonie.
    Fleet.TestEnv.delete_role_token!("gatekeeper")

    assert {:error, {:close_after_merge, :role_token_unavailable}} =
             MergeAndPromote.merge_and_promote(OkForge, "fleet/myproj", 7, 42, "engineer", [],
               base_branch: "main"
             )

    # ⚠ ON CIBLE LA SIGNATURE, PAS « un commentaire ». La note de mur de provenance est elle aussi un
    # commentaire, et elle DOIT partir : signée SYSTÈME, elle dit un fait mécanique, pas une
    # promotion. Un `refute_received {:comment, ...}` nu échouait dessus — il aurait interdit un
    # message qu'on veut voir. (`refute_received` n'accepte pas `opts[...]` en garde : on vide la
    # boîte et on filtre en code.)
    msgs = drain_mailbox()

    refute Enum.any?(msgs, fn
             {:comment, _, _, _, opts} -> opts[:dedup_signature] == "[merge:pr-7]"
             _ -> false
           end),
           "le commentaire de promotion ne doit PAS partir sans le jeton du rail décision"

    refute Enum.any?(msgs, &match?({:close_issue, _, _, _}, &1)),
           "la fermeture est un acte du rail décision — pas de jeton, pas de fermeture"

    assert Enum.any?(msgs, &match?({:worktree_sync, "fleet/myproj", "main"}, &1)),
           "la brique EST fusionnée : la projection a lieu quoi qu'il arrive à la cérémonie"
  end

  # Vide la boîte du test et rend les messages dans l'ordre. Nécessaire dès qu'on doit RAISONNER sur
  # l'ensemble des messages plutôt que d'en attendre un : les gardes de `refute_received` ne peuvent
  # pas lire une keyword list.
  defp drain_mailbox(acc \\ []) do
    receive do
      msg -> drain_mailbox([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "F-C066 — merge OK but close FAILS (persistent) → seal {:error, {:close_after_merge, _}} + LOUD log, projection anyway" do
    # A discarded `_ = close_issue` → failed close → seal returning `:ok` → MERGED brick stays OPEN →
    # re-dispatched every tick, in SILENCE (the RETURN lied). F-C066: HONEST return (the merge
    # succeeded but the close did not) after bounded retry + LOUD log. The caller then skips the
    # unlock (issue keeps lcars-in-flight) and `decide/1` skips `stage/merged` → never re-dispatched.
    # Token placed by the setup.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:close_after_merge, _}} =
                 MergeAndPromote.merge_and_promote(
                   CloseFailForge,
                   "fleet/myproj",
                   7,
                   42,
                   "engineer",
                   [],
                   base_branch: "main"
                 )
      end)

    assert log =~ "close FAILED"

    # The merge did happen → the worktree projection IS triggered (the failed close does not
    # invalidate the merge).
    assert_received {:worktree_sync, "fleet/myproj", "main"}
  end
end

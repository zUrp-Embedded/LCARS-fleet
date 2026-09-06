defmodule Fleet.Pilot.MergeAndPromoteTest do
  @moduledoc """
  SINGLE merge seal (F-arch-MCP): signed merge THEN signed gatekeeper comment. The merge is the
  source of truth — NEVER a "merged" claim before reality (F-MERGE-CLAIM-BEFORE-REALITY). The
  gatekeeper signature is applied INTERNALLY by `merge_and_promote` (les deux jetons de rail → RoleToken): the
  gatekeeper account token comes from a controlled tmp_dir (never the runner's real
  `/opt/lcars/var/tokens`). async: false (mutates the global `:role_tokens_dir` config).
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ForgeStubs.{CloseFailForge, MergeFailForge, OkForge}
  alias Fleet.Pilot.MergeAndPromote
  alias Fleet.TestEnv

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    # ⚖ DEUX JETONS, ET C'EST LE CHANGEMENT DE 2026-08-20. Le sceau ne signe plus tout avec un seul
    # rôle : le rail MERGE (`chief`) fusionne, pousse et supprime la branche ; le rail DÉCISION
    # (`gatekeeper`) commente la promotion et ferme. Un `setup` qui ne posait que le gatekeeper
    # décrivait le monde d'avant — et le faisait passer pour le monde tout court.
    #
    # Les deux sont résolus EN TÊTE et fail-closed ensemble : la contrepartie assumée est qu'un
    # merge propre dépend désormais du jeton du chief, alors qu'il ne le touchait pas avant. C'est
    # tenable parce que le boot les exige déjà tous les deux
    # (`Pilot.Application.require_signer_tokens!`) — ici, une absence est une PERTE en vol, pas un
    # trou de provisioning.
    TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)
    TestEnv.put_role_token!("gatekeeper", "GK-TOKEN")
    TestEnv.put_role_token!("chief", "CHIEF-TOKEN")

    :ok
  end

  defmodule CommentFailForge do
    # Read by the seal before it names who approved (it must not claim verdicts that do not
    # exist). No jury in this stub -> empty verdicts.
    # A0 — clean PR by default: the seal reads the conflict signal, 0 marks -> method "rebase".
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def get_route(_r, _n, _o), do: :none

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def post_comment(_r, _n, _b, _o), do: {:error, {:http, 500, "boom"}}

    def merge_pr(_r, _pr, _o) do
      send(self(), :merged)
      :ok
    end

    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}
    def close_issue(_r, _n, _o), do: {:ok, :closed}
  end

  # F-C066 — FLAKY close: fails 2×, succeeds the 3rd (process-dict counter) → proves self-heal via retry.
  defmodule CloseFlakyForge do
    # Read by the seal before it names who approved (it must not claim verdicts that do not
    # exist). No jury in this stub -> empty verdicts.
    # A0 — clean PR by default: the seal reads the conflict signal, 0 marks -> method "rebase".
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def merge_pr(_r, _pr, _o), do: :ok
    def post_comment(_r, _n, _b, _o), do: {:ok, :posted}
    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}

    def close_issue(_r, n, _o) do
      attempt = (Process.get({:close_attempts, n}) || 0) + 1
      Process.put({:close_attempts, n}, attempt)
      send(self(), {:close_attempt, n, attempt})
      if attempt < 3, do: {:error, {:http, 500, "flaky"}}, else: {:ok, :closed}
    end
  end

  # CI-06 — FLAKY stage/merged: fails 2×, succeeds the 3rd → proves the load-bearing projection self-heals
  # via its retry (mirror of the close retry). merge/comment/close all OK.
  defmodule StageFlakyForge do
    # Read by the seal before it names who approved (it must not claim verdicts that do not
    # exist). No jury in this stub -> empty verdicts.
    # A0 — clean PR by default: the seal reads the conflict signal, 0 marks -> method "rebase".
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def merge_pr(_r, _pr, _o), do: :ok
    def post_comment(_r, _n, _b, _o), do: {:ok, :posted}
    def close_issue(_r, _n, _o), do: {:ok, :closed}

    def set_stage(_r, n, _s, _o) do
      attempt = (Process.get({:stage_attempts, n}) || 0) + 1
      Process.put({:stage_attempts, n}, attempt)
      send(self(), {:stage_attempt, n, attempt})
      if attempt < 3, do: {:error, {:http, 500, "flaky stage"}}, else: {:ok, :posted}
    end
  end

  test "DEUX RAILS : le merge signe chief, le commentaire et la fermeture signent gatekeeper" do
    # RAW forge_opts (system token): les deux signatures sont appliquées EN INTERNE par
    # `merge_and_promote` — les jetons de rôle ÉCRASENT celui du système, et il y en a deux.
    #
    # ⚖ CE TEST A ÉTÉ RETOURNÉ (user, 2026-08-20). Il épinglait « merge, commentaire et fermeture
    # portent TOUS le jeton gatekeeper », ce qui était vrai et faux à la fois : vrai du code,
    # faux du modèle. Fusionner est une EXÉCUTION, et le gatekeeper déclare `brief_kind: judge`
    # — « never execute what you judge », propriété de sécurité que le schéma exige de déclarer.
    # Le rail qui juge signait donc l'écriture git sur 90 % des PR.
    forge_opts = [token: "system-token"]

    assert :ok =
             MergeAndPromote.merge_and_promote(OkForge, "fleet/p", 7, 42, "engineer", forge_opts,
               base_branch: "main"
             )

    # RAIL MERGE — la fusion (et, avec elle, la poussée sur main et la suppression de branche que
    # Gitea attribue au même compte : un seul appel, un seul doer, aucun paramètre d'acteur sur
    # l'endpoint — mesuré sur 1.26.1).
    assert_received {:merge, "fleet/p", 7, m_opts}
    assert m_opts[:token] == "CHIEF-TOKEN"

    assert_received {:comment, "fleet/p", 42, body, c_opts}
    assert body =~ "Brique #42"
    assert body =~ "`engineer`"
    assert body =~ "[merge:pr-7]"

    # RAIL DÉCISION — le commentaire de promotion, + dedup author-agnostic (sinon double-post au
    # retry, et la raison est plus forte qu'avant : DEUX comptes écrivent maintenant sur ce ticket).
    assert c_opts[:token] == "GK-TOKEN"
    assert c_opts[:dedup_signature] == "[merge:pr-7]"
    assert c_opts[:dedup_any_author] == true

    # RAIL DÉCISION — la fermeture. C'est la promotion qui ferme, pas la fusion.
    assert_received {:close_issue, "fleet/p", 42, close_opts}
    assert close_opts[:token] == "GK-TOKEN"

    # SYSTÈME — et c'est le troisième acteur, celui qu'on oublie. Le label `stage/merged` ne porte
    # AUCUN jeton de rôle : ni chief, ni gatekeeper. WS1 (tous les `stage/*` sont système), et ce
    # n'est pas une préférence de style — le chemin dégradé `converge_out_of_band_merge` n'a aucun
    # jeton de rôle disponible et doit pourtant pouvoir poser ce label, qui est la garde
    # anti-redispatch d'une brique fusionnée.
    #
    # Sans cette assertion, substituer `merge_opts` à `forge_opts` sur cet appel violait WS1 en
    # silence, suite verte (mutation nommée par la revue du 2026-08-20).
    assert_received {:set_stage, "fleet/p", 42, _stage, stage_opts}
    assert stage_opts[:token] == "system-token"
  end

  # ⚠ MESURE DU BANC, 2026-08-20 — `fleet/chifoumi` ticket #4, `merged_by: system_chief` à la forge,
  # et LE MÊME COMMENTAIRE annonçant trois lignes plus bas « puis le `gatekeeper` (habilité au merge)
  # scelle ». La note interim avait survécu à la séparation des rails.
  #
  # POURQUOI RIEN NE L'AVAIT ATTRAPÉE, et c'est la seule chose utile à retenir : le lot D a corrigé
  # tout ce qui NOMMAIT un signataire — `signer_line`, `validation_line`, les logs. Cette note-là ne
  # nomme pas un signataire, elle décrit une HABILITATION, donc aucune relecture pilotée par
  # « qui signe » ne pouvait la voir. Et le test ci-dessus épingle les JETONS, pas la prose : une
  # suite verte ne lit pas le texte qu'elle produit.
  #
  # D'où ce test, qui épingle la prose elle-même. Il est plus sévère que la note : il refuse au
  # commentaire ENTIER d'attribuer la fusion au rail décision, où que ce soit.
  test "la PROSE du sceau n'attribue jamais la fusion au gatekeeper — le banc l'a prise en défaut" do
    forge_opts = [token: "system-token"]

    assert :ok =
             MergeAndPromote.merge_and_promote(OkForge, "fleet/p", 7, 42, "engineer", forge_opts,
               base_branch: "main"
             )

    assert_received {:comment, "fleet/p", 42, body, _opts}

    # Ce que le texte DOIT dire : chaque rail à son acte.
    assert body =~ "rail merge"
    assert body =~ "rail décision"

    # Ce qu'il ne doit JAMAIS dire. Fusionner est une exécution, et le gatekeeper déclare
    # `brief_kind: judge` — « never execute what you judge ».
    refute body =~ "habilité au merge"

    for phrase <- ["gatekeeper` (habilité", "gatekeeper fusionne", "gatekeeper` fusionne"] do
      refute body =~ phrase, "le sceau attribue la fusion au rail décision : #{inspect(phrase)}"
    end
  end

  test "merge KO → {:error, {:merge, _}} AND NO \"merged\" claim posted (no lie before reality)" do
    assert {:error, {:merge, {:http, 409, _}}} =
             MergeAndPromote.merge_and_promote(MergeFailForge, "fleet/p", 7, 42, "engineer", [],
               base_branch: "main"
             )

    # THE crucial point (F-MERGE-CLAIM-BEFORE-REALITY): failed merge → we did NOT claim "delivered
    # and merged".
    refute_received {:comment, _, _, _, _}
  end

  # The merge POST times out — but the SERVER committed the merge before the reply was cut.
  # The old seal skipped every postcondition on any merge error: the merged brick kept no
  # stage/merged, stayed open with an orphaned lock, and the reconciliation re-dispatched an
  # already-merged brick (double-delivery).
  defmodule TimeoutButMergedForge do
    # Read by the seal before it names who approved (it must not claim verdicts that do not
    # exist). No jury in this stub -> empty verdicts.
    # A0 — clean PR by default: the seal reads the conflict signal, 0 marks -> method "rebase".
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def merge_pr(_r, _pr, _o), do: {:error, {:http, :timeout, "reply cut mid-flight"}}
    def get_pull(_r, _pr, _o), do: {:ok, %{"merged" => true, "state" => "closed"}}

    def post_comment(r, n, b, o) do
      send(self(), {:comment, r, n, b, o})
      {:ok, :posted}
    end

    def set_stage(r, n, s, o) do
      send(self(), {:set_stage, r, n, s, o})
      {:ok, :posted}
    end

    def close_issue(r, n, o) do
      send(self(), {:close_issue, r, n, o})
      {:ok, :closed}
    end
  end

  # Same timeout, but the readback says the PR is NOT merged → the error must propagate
  # untouched (fail-closed), and nothing may post.
  defmodule TimeoutNotMergedForge do
    # Read by the seal before it names who approved (it must not claim verdicts that do not
    # exist). No jury in this stub -> empty verdicts.
    # A0 — clean PR by default: the seal reads the conflict signal, 0 marks -> method "rebase".
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def merge_pr(_r, _pr, _o), do: {:error, {:http, :timeout, "reply cut mid-flight"}}

    def get_pull(_r, _pr, _o),
      do: {:ok, %{"merged" => false, "state" => "open", "mergeable" => true}}

    def post_comment(r, n, b, o) do
      send(self(), {:comment, r, n, b, o})
      {:ok, :posted}
    end

    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}
    def close_issue(_r, _n, _o), do: {:ok, :closed}
  end

  test "merge POST errors but the SERVER says merged → the seal CONVERGES its postconditions" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 MergeAndPromote.merge_and_promote(
                   TimeoutButMergedForge,
                   "fleet/p",
                   7,
                   42,
                   "engineer",
                   [token: "system-token"],
                   base_branch: "main"
                 )
      end)

    # The full postcondition queue ran from the readback proof: seal comment, stage/merged,
    # explicit close — the merged brick can neither stay open nor be re-dispatched.
    assert_received {:comment, "fleet/p", 42, body, _}
    assert body =~ "[merge:pr-7]"
    assert_received {:set_stage, "fleet/p", 42, _, _}
    assert_received {:close_issue, "fleet/p", 42, _}
    assert log =~ "SERVER says merged"
  end

  test "merge POST errors and the readback says NOT merged → error propagates, nothing posts" do
    assert {:error, {:merge, {:http, :timeout, _}}} =
             MergeAndPromote.merge_and_promote(
               TimeoutNotMergedForge,
               "fleet/p",
               7,
               42,
               "engineer",
               [token: "system-token"],
               base_branch: "main"
             )

    refute_received {:comment, _, _, _, _}
  end

  # The merge is the act that counts; the comment is a POST-merge trace, best-effort: a failed seal
  # comment does NOT block the seal (the merge stays authoritative), but it is LOGGED loud — nothing
  # re-posts it (the dedup only guards against replays), so the loss is visible in the log, never
  # silent. Only the human-readable trace is lost, never the merge.
  test "comment KO AFTER merge → :ok anyway (the merge counts, the lost trace is LOGGED, not silent)" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 MergeAndPromote.merge_and_promote(
                   CommentFailForge,
                   "fleet/p",
                   7,
                   42,
                   "engineer",
                   [],
                   base_branch: "main"
                 )
      end)

    assert_received :merged
    assert log =~ "seal comment NOT posted"
  end

  test "F-C066: merge OK but close failed (persistent) → {:error, {:close_after_merge, _}}, NEVER a lying :ok" do
    # Core of the finding: returning `:ok` even when `close_issue` fails (log-loud then `:ok`) →
    # the caller believed the brick sealed while the issue stayed OPEN → re-dispatch →
    # double-delivery. Instead: HONEST typed return (the merge succeeded, but the close did not).
    assert {:error, {:close_after_merge, {:http, 500, "close boom"}}} =
             MergeAndPromote.merge_and_promote(CloseFailForge, "fleet/p", 7, 42, "engineer", [],
               base_branch: "main"
             )

    # BOUNDED retry: 3 close attempts before giving up (then honest return).
    assert_received {:close_attempt, 42}
    assert_received {:close_attempt, 42}
    assert_received {:close_attempt, 42}
    refute_received {:close_attempt, 42}
  end

  test "CI-06: FLAKY stage/merged (fails 2×) → self-heals via retry, the load-bearing label lands, seal :ok" do
    # Pre-CI-06 the set_stage failure was discarded UN-retried → the load-bearing `stage/merged` label
    # was lost on a transient blip → Delegation read `closed_without_merge` forever (arch waits on a
    # merged brick). Now retried (mirror of the close retry): a transient failure self-heals.
    assert :ok =
             MergeAndPromote.merge_and_promote(StageFlakyForge, "fleet/p", 7, 42, "engineer", [],
               base_branch: "main"
             )

    assert_received {:stage_attempt, 42, 1}
    assert_received {:stage_attempt, 42, 2}
    assert_received {:stage_attempt, 42, 3}
    refute_received {:stage_attempt, 42, _}
  end

  test "F-C066: flaky close (fails 2×, succeeds the 3rd) → retry → :ok (self-heal of a transient blip)" do
    assert :ok =
             MergeAndPromote.merge_and_promote(CloseFlakyForge, "fleet/p", 7, 42, "engineer", [],
               base_branch: "main"
             )

    assert_received {:close_attempt, 42, 1}
    assert_received {:close_attempt, 42, 2}
    assert_received {:close_attempt, 42, 3}
  end

  # ── Provenance wall (Phase 2) — systematic, card-independent ──────────────
  # Harness and forge shared with the completer and dispatcher witnesses
  # (`Fleet.Test.ProvenanceWallHarness`, test/support/pilot/).
  alias Fleet.Test.ProvenanceWallHarness, as: Wall
  alias Fleet.Test.ProvenanceWallHarness.WallForge

  defp wall_harness(tmp), do: Wall.harness(tmp)
  defp wall_statement(tmp, issue_n, head, input), do: Wall.statement(tmp, issue_n, head, input)
  defp wall_opts(tmp, head), do: Wall.opts(tmp, head)

  @tag :requires_git
  test "provenance wall: an INCOHERENT statement REFUSES the merge (deterministic, no LLM)",
       %{tmp_dir: tmp} do
    %{head: head, alien: alien} = wall_harness(tmp)
    :ok = wall_statement(tmp, 9, head, alien)

    assert {:error, {:provenance_incoherent, {:base_not_ancestor, ^alien, ^head}}} =
             MergeAndPromote.merge_and_promote(
               WallForge,
               "fleet/demo",
               4,
               9,
               "engineer",
               wall_opts(tmp, head),
               Keyword.put(wall_opts(tmp, head), :base_branch, "main")
             )

    # THE point: nothing merged; the wall's user-facing trace is on the PR.
    refute_received {:merge, _}
    assert_received {:comment, 4, body, "[provenance-wall:pr-4]"}
    assert body =~ "Provenance incohérente"
  end

  @tag :requires_git
  test "provenance wall: a COHERENT statement lets the seal proceed", %{tmp_dir: tmp} do
    %{base: base, head: head} = wall_harness(tmp)
    :ok = wall_statement(tmp, 9, head, base)

    assert :ok =
             MergeAndPromote.merge_and_promote(
               WallForge,
               "fleet/demo",
               4,
               9,
               "engineer",
               wall_opts(tmp, head),
               Keyword.put(wall_opts(tmp, head), :base_branch, "main")
             )

    assert_received {:merge, 4}
  end

  @tag :requires_git
  test "provenance wall: une preuve pour un AUTRE sha ne peut plus etre confondue avec la preuve de la brique (BL-6-43)",
       %{tmp_dir: tmp} do
    # LE CAS 4 NE PEUT PLUS EXISTER, et ce test le prouve par CONSTRUCTION plutot que par detection.
    # Avant : le fichier d'attestation portait un nom DERIVE de la tete, donc une tete qui bougeait
    # apres la gravure faisait chercher un nom que personne n'avait ecrit — et une preuve pour un
    # autre commit, posee a cote, se lisait exactement comme une absence.
    #
    # Maintenant la ref EST le sha. On grave pour `alien`, on scelle `head` : la preuve d'`alien`
    # existe, elle est intacte, et elle n'est simplement PAS la preuve de `head`. Aucune confusion
    # possible, aucun nom a calculer.
    %{head: head, base: base, alien: alien} = wall_harness(tmp)
    :ok = wall_statement(tmp, 9, alien, base)

    proj = Path.join([tmp, "p", "demo"])

    # La preuve d'alien est bien la, lisible, sous SON sha.
    assert {:ok, _} = Fleet.Workflow.Git.read_provenance(proj, alien)
    # Et il n'y en a aucune sous celui qu'on scelle — la question ne se pose meme pas.
    assert {:error, :no_provenance_ref} = Fleet.Workflow.Git.read_provenance(proj, head)
  end

  @tag :requires_git
  test "provenance wall SAUTÉ : le merge passe, ET la PR le DIT (BL-6-47.4)", %{tmp_dir: tmp} do
    # L'asymétrie fermée ici : les deux branches voisines loguaient, une seule écrivait SUR LA
    # FORGE. Une PR mergée avait donc exactement la même apparence, que le mur l'ait vérifiée ou
    # qu'il n'ait jamais tourné — « mergée » suggérait une provenance contrôlée. Le log ne rattrape
    # pas ça : la PR est l'artefact qu'un humain relit six mois plus tard, pas les journaux du BEAM.
    %{head: head} = wall_harness(tmp)
    # PAS de `wall_statement/4` → `{:skip, {:no_statement, ref}}`.

    assert :ok =
             MergeAndPromote.merge_and_promote(
               WallForge,
               "fleet/demo",
               4,
               9,
               "engineer",
               wall_opts(tmp, head),
               Keyword.put(wall_opts(tmp, head), :base_branch, "main")
             )

    # Le merge n'est PAS bloqué — le chemin reste délibérément non-bloquant, le fix rend la
    # décision lisible, il ne la renverse pas.
    assert_received {:merge, 4}

    # Et la trace existe, sous une signature DISTINCTE de celle du refus : confondre les deux
    # ferait qu'une note « non vérifiée » dédupliquerait un vrai refus, ou l'inverse.
    assert_received {:comment, 4, body, "[provenance-wall-skipped:pr-4]"}
    assert body =~ "Provenance NON vérifiée"
    assert body =~ "no_statement"
    refute body =~ "Provenance incohérente"
  end

  # ─── A0 — conflict signal → merge METHOD ────────────────────────────────────────────────────────

  defmodule ConflictForge do
    @moduledoc "A PR that went through a conflict: the chief round marker is on it."
    def count_comments_marked(repo, n, prefix, opts) do
      send(self(), {:count_marked, repo, n, prefix, opts})
      if String.starts_with?(prefix, "[conflict-chief:pr-"), do: {:ok, 1}, else: {:ok, 0}
    end

    def post_comment(repo, n, body, opts) do
      send(self(), {:comment, repo, n, body, opts})
      {:ok, :posted}
    end

    def merge_pr(repo, pr, opts) do
      send(self(), {:merge, repo, pr, opts})
      :ok
    end

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}
    def close_issue(_repo, _n, _opts), do: {:ok, :closed}
  end

  defmodule SignalDownForge do
    @moduledoc "The conflict signal cannot be read — the seal must REFUSE, before any write."
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:error, {:http, 500, "boom"}}

    def merge_pr(repo, pr, opts) do
      send(self(), {:merge, repo, pr, opts})
      :ok
    end

    def post_comment(repo, n, body, opts) do
      send(self(), {:comment, repo, n, body, opts})
      {:ok, :posted}
    end
  end

  describe "A0 — the conflict signal picks the merge method" do
    test "no marker → method \"rebase\" (the historic behavior, byte-for-byte)" do
      assert :ok =
               MergeAndPromote.merge_and_promote(OkForge, "fleet/p", 7, 42, "engineer", [],
                 base_branch: "main"
               )

      assert_received {:merge, "fleet/p", 7, opts}
      assert Keyword.get(opts, :method) == "rebase"
    end

    test "un marqueur de conflit → méthode \"merge\", et le TEXTE le dit — la signature, elle, ne change pas" do
      # ⚖ CE TEST A ÉTÉ RETOURNÉ (user, 2026-08-20), et c'est le piège de la séparation des rails.
      # Il épinglait « conflit résolu ⟹ SIGNÉ CHIEF », c'est-à-dire une signature CONDITIONNELLE au
      # fait qu'un conflit ait eu lieu. Le chief signe désormais TOUS les merges — donc la signature
      # ne discrimine plus rien, et ce qui reste conditionnel est la MÉTHODE.
      #
      # Collapser les deux ensemble aurait dé-résolu tous les conflits : `Do: rebase` DROPPE le
      # commit de fusion qui porte la résolution. C'est la seule moitié de l'ancienne conditionnelle
      # qui devait survivre, et ce test est ce qui l'empêche de partir avec l'autre.
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_resolver_role, "chief")

      assert :ok =
               MergeAndPromote.merge_and_promote(ConflictForge, "fleet/p", 7, 42, "engineer", [],
                 base_branch: "main"
               )

      assert_received {:merge, "fleet/p", 7, opts}
      assert Keyword.get(opts, :method) == "merge"
      assert Keyword.get(opts, :token) == "CHIEF-TOKEN"

      # Le fait « conflit » vit maintenant dans la MÉTHODE, jamais dans la signature — et le texte
      # le déduit de ce qui a réellement été employé.
      assert_received {:comment, "fleet/p", 42, body, _opts}
      assert body =~ "conflit résolu"
      refute body =~ "historique linéaire"
    end

    test "jeton du rail MERGE manquant → refus fail-closed, jamais un repli sur l'autre rail" do
      # Le jeton de l'AUTRE rail est disponible (le `setup` pose les deux, on retire celui-ci) —
      # s'y replier ferait signer une exécution par le rail qui juge. La PR reste non fusionnée et
      # rien n'est écrit.
      #
      # ⚠ Ce test couvre désormais TOUTES les PR, pas seulement les conflictuelles : depuis que le
      # chief fusionne à tous les coups, un merge propre dépend lui aussi de son jeton. C'est la
      # contrepartie assumée de la séparation, et le boot l'exige déjà des deux
      # (`require_signer_tokens!`) — une absence ici est une PERTE en vol.
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_resolver_role, "chief")
      TestEnv.delete_role_token!("chief")

      assert {:error, :role_token_unavailable} =
               MergeAndPromote.merge_and_promote(OkForge, "fleet/p", 7, 42, "engineer", [],
                 base_branch: "main"
               )

      refute_received {:merge, _, _, _}
      refute_received {:comment, _, _, _, _}
    end

    test "signal unreadable → seal REFUSED before any write (fail-loud, never a blind rebase)" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:conflict_signal_unreadable, _}} =
                   MergeAndPromote.merge_and_promote(
                     SignalDownForge,
                     "fleet/p",
                     7,
                     42,
                     "engineer",
                     [],
                     base_branch: "main"
                   )
        end)

      refute_received {:merge, _, _, _}
      refute_received {:comment, _, _, _, _}
      assert log =~ "conflict signal UNREADABLE"
    end
  end

  # ═══ A5 — LA VÉRIFICATION POST-HOC DE LA SONDE ═══
  #
  # Arbitrage Q1 : la sonde est TIRÉE par le juge, donc rien ne peut le forcer à l'appeler au moment
  # où il rend son verdict. Ce qui devient mécanique, c'est le CONSTAT — la forge tient le registre
  # des runs par `head_sha`. Politique : ANNOTER, jamais rejeter. Rejeter referait de la sonde une
  # précondition par la porte de derrière, et le doc 14 pose qu'elle est un gain.
  describe "A5 — le sceau constate si la tête a été sondée, et n'en fait jamais un mur" do
    # `OkForge` décrit un dépôt SANS jury, et l'absence de sonde n'y veut rien dire. Il fallait donc
    # un stub qui porte de vrais avis favorables : c'est la seule forme où « rendu sans mesure » est
    # une phrase qui a un sens.
    defmodule JuryForge do
      @moduledoc false
      defdelegate count_comments_marked(r, n, p, o), to: OkForge
      defdelegate post_comment(r, n, b, o), to: OkForge
      defdelegate merge_pr(r, pr, o), to: OkForge
      defdelegate set_stage(r, n, s, o), to: OkForge
      defdelegate close_issue(r, n, o), to: OkForge
      defdelegate pr_refs(r, pr, o), to: OkForge
      def get_route(_r, _n, _o), do: :none

      def pr_review_state(_repo, _n, _opts),
        do:
          {:ok,
           %{
             verdicts: %{"fleet_qualifier" => :approved, "fleet_reviewer" => :approved},
             reviewers: ["fleet_qualifier", "fleet_reviewer"],
             outcome: :approved
           }}
    end

    # Les trois stubs SIGNALENT leur appel : c'est ce qui rend les `refute` ci-dessous
    # discriminants. Sans ce signal, « aucune mention » est vrai pour `:probed`, pour `:unknown`,
    # et pour tout chemin qui n'a jamais interrogé la sonde — trois faits opposés, une assertion.
    defmodule Probed do
      @moduledoc false
      def probed?(repo, sha, _opts) do
        send(self(), {:probed_asked, repo, sha})
        {:ok, true}
      end
    end

    defmodule Unprobed do
      @moduledoc false
      def probed?(repo, sha, _opts) do
        send(self(), {:probed_asked, repo, sha})
        {:ok, false}
      end
    end

    defmodule Unreadable do
      @moduledoc false
      def probed?(repo, sha, _opts) do
        send(self(), {:probed_asked, repo, sha})
        {:error, {:http, 503, "nope"}}
      end
    end

    defp seal_body(actions) do
      TestEnv.put_env_restoring(:lcars_fleet, :forge_actions, actions)

      assert :ok =
               MergeAndPromote.merge_and_promote(JuryForge, "fleet/p", 7, 42, "engineer", [],
                 base_branch: "main"
               )

      assert_received {:comment, "fleet/p", 42, body, _}
      body
    end

    test "tête NON sondée + des juges → la mention est écrite, et le merge a quand même eu lieu" do
      body = seal_body(Unprobed)

      assert body =~ "Aucune sonde n'a tourné sur cette tête"

      # ⚠ LA MOITIÉ QUI COMPTE. Le verdict reste valable et la brique est fusionnée : la mention
      # documente une base plus étroite, elle ne refuse rien.
      assert_received {:merge, "fleet/p", 7, _}
      assert body =~ "livrée et fusionnée"
    end

    # ⚠ CES DEUX TESTS ÉTAIENT NON-DISCRIMINANTS, ET UNE RELECTURE ADVERSARIALE L'A DIT. Ils
    # vérifiaient l'ABSENCE d'une mention — or `:probed` ET `:unknown` produisent tous deux `""`,
    # donc chacun passait aussi pour la mauvaise raison : un `pr_refs` cassé, un `forge_actions`
    # non installé, n'importe quel court-circuit du `with` dans `probe_state/4`.
    #
    # On mesure donc maintenant CE QUE LA SONDE A RÉPONDU, pas seulement ce que le texte ne dit
    # pas : chaque stub SIGNALE son appel, et le test exige que le chemin ait été traversé.
    test "tête SONDÉE → la lecture a bien eu lieu, ET aucune ligne n'est écrite" do
      body = seal_body(Probed)

      # Le chemin est traversé — sans ça, l'assertion suivante serait vraie pour dix raisons.
      assert_received {:probed_asked, "fleet/p", "deadbeef"}
      # Une ligne qui dit la même chose sur chaque ticket cesse d'être lue au troisième.
      refute body =~ "Aucune sonde"
    end

    test "lecture IMPOSSIBLE → la question a été posée, et RIEN n'est affirmé" do
      body = seal_body(Unreadable)

      assert_received {:probed_asked, "fleet/p", "deadbeef"}

      # `:unknown` est distinct de « personne n'a mesuré ». Les confondre écrirait sur le ticket un
      # fait produit par une forge injoignable.
      refute body =~ "Aucune sonde"
    end

    test "zéro juge → la sonde n'est même pas INTERROGÉE (rien à annoter)" do
      # ⚠ CE TEST ÉTAIT TAUTOLOGIQUE : il installait `Unprobed` alors que la clause
      # `probe_note([], _)` court-circuite AVANT de regarder l'état de sonde. L'override n'était
      # jamais consulté, et le test passait avec n'importe quoi — y compris rien.
      #
      # Il mesure maintenant la propriété qui compte VRAIMENT : sur un dépôt sans jury, aucun
      # verdict n'a été rendu, donc l'absence de sonde ne dit rien — et le sceau ne dépense même
      # pas la lecture forge pour s'en assurer.
      TestEnv.put_env_restoring(:lcars_fleet, :forge_actions, Unprobed)

      assert :ok =
               MergeAndPromote.merge_and_promote(OkForge, "fleet/p", 7, 42, "engineer", [],
                 base_branch: "main"
               )

      assert_received {:comment, "fleet/p", 42, body, _}
      refute body =~ "Aucune sonde"
    end
  end
end

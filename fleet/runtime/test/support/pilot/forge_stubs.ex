defmodule Fleet.Pilot.ForgeStubs do
  @moduledoc """
  Stubs ForgeClient partagés entre fichiers de test de fleet_pilot (dédup B6) : les deux tests du
  sceau gatekeeper (`gatekeeper_seal_test` / `gatekeeper_seal_worktree_test`) et le completer
  (`step_run_completer_test`) redéfinissaient chacun leur OkForge / MergeFailForge.

  Espions : les write-ops forge `send(self(), …)`. L'appelant (`seal_and_merge`, `complete_pr`)
  tourne DANS le process du test (appels directs, pas de GenServer) → les messages arrivent à la
  mailbox du test. Un test qui n'asserte pas ces messages les ignore sans coût.
  """

  defmodule OkForge do
    @moduledoc """
    Forge où tout réussit. `post_comment` / `merge_pr` signalent (`{:comment, repo, n, body, opts}`
    / `{:merge, repo, pr, opts}`) pour prouver l'ORDRE des écritures du sceau et leur SIGNATURE
    (le token de rôle dans `opts`).
    """
    def post_comment(repo, n, body, opts) do
      send(self(), {:comment, repo, n, body, opts})
      {:ok, 1}
    end

    def merge_pr(repo, pr, opts) do
      send(self(), {:merge, repo, pr, opts})
      :ok
    end

    # WS2 : le sceau pose stage/merged post-merge (best-effort). No-op (le stub prouve l'ordre merge↔comment).
    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}

    # Close explicite (QoL 2026-07-07) : dernier acte de seal_and_merge. SIGNALE (opts inclus) : un test
    # (GatekeeperSealTest) prouve que le close est signé GATEKEEPER, même identité que merge_pr/comment
    # (régression QoL 2026-07-07 : le close partait signé système, rupture d'identité dans le sceau).
    def close_issue(repo, n, opts) do
      send(self(), {:close_issue, repo, n, opts})
      {:ok, :closed}
    end
  end

  defmodule CloseFailForge do
    @moduledoc "Merge OK mais `close_issue` ÉCHOUE — prouve que le sceau LOG LOUD (brique mergée reste OUVERTE)."
    def post_comment(_repo, _n, _body, _opts), do: {:ok, 1}
    def merge_pr(_repo, _pr, _opts), do: :ok
    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}
    def close_issue(_repo, _n, _opts), do: {:error, {:http, 500, "close boom"}}
  end

  defmodule MergeFailForge do
    @moduledoc """
    Forge dont le merge échoue (`{:http, 409, "not fast-forward"}`). `post_comment` SIGNALE
    (`{:comment, repo, n, body, opts}`) → un test prouve qu'AUCUN « fusionnée » n'est posté quand
    le merge est KO (F-MERGE-CLAIM-BEFORE-REALITY) via `refute_received`. `open_pr` réussit
    (`{:ok, 7}`) : le chemin completer `:promote` ouvre la PR PUIS échoue au merge — les tests du
    sceau, eux, n'appellent jamais `open_pr` (fonction surnuméraire inoffensive).
    """
    def open_pr(_repo, _head, _base, _title, _opts), do: {:ok, 7}

    def post_comment(repo, n, body, opts) do
      send(self(), {:comment, repo, n, body, opts})
      {:ok, 1}
    end

    def merge_pr(_repo, _pr, _opts), do: {:error, {:http, 409, "not fast-forward"}}

    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}
  end
end

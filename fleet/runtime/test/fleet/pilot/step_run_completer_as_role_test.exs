defmodule Fleet.Pilot.StepRunCompleterAsRoleTest do
  # async: false — mute la config globale `:role_tokens_dir` (cf. Fleet.Credentials.RoleTokenTest).
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepRunCompleter

  @moduletag :tmp_dir

  # F-E6 — capture le `token` des forge_opts passés à `post_comment` : le commentaire de VERDICT doit
  # être AU NOM DU JUGE (token de rôle), pas du compte système. Les labels restent système (non capturés).
  defmodule TokenCaptureForge do
    def post_comment(_repo, _n, _body, opts) do
      send(self(), {:comment_token, opts[:token]})
      {:ok, :posted}
    end

    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
    def remove_label(_repo, _n, _label, _opts), do: {:ok, :removed}
    def start_stopwatch(_repo, _n, _opts), do: :ok

    # QoL 2026-07-07 : capture (n, token) — prouve que le stop du verrou ISSUE (démarré par le
    # PRODUCTEUR, persistant toute la review) est signé PRODUCTEUR même quand c'est un JUGE qui
    # termine la brique (route(:promote)), tandis que le stop du verrou PR reste signé JUGE (son
    # propre tour). Deux stops, deux identités distinctes, jamais confondues.
    def stop_stopwatch(_repo, n, opts) do
      send(self(), {:stop_stopwatch, n, opts[:token]})
      :ok
    end

    def close_issue(_repo, _n, _opts), do: {:ok, :closed}
    def post_route(_repo, _n, _workflow_map_name, _step, _opts), do: {:ok, :posted}

    def get_pr_for_branch(_repo, head, base, _opts),
      do: send(self(), {:get_pr, head, base}) && {:ok, 7}

    def post_review(_repo, pr, event, body, _opts),
      do: send(self(), {:review, pr, event, body}) && :ok

    def merge_pr(_repo, pr, _opts), do: send(self(), {:merge, pr}) && :ok
    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}
  end

  setup %{tmp_dir: tmp} do
    # token de rôle consultant résoluble → `as_role("consultant")` doit l'injecter.
    File.write!(Path.join(tmp, "consultant.gitea_token"), "tok-consultant")
    File.write!(Path.join(tmp, "reviewer.gitea_token"), "tok-reviewer")
    File.write!(Path.join(tmp, "engineer.gitea_token"), "tok-engineer")

    # :promote passe par `GatekeeperSeal.seal_and_merge` (fail-closed, soft-default #3) → token gatekeeper requis.
    File.write!(Path.join(tmp, "gatekeeper.gitea_token"), "tok-gatekeeper")
    Fleet.Pilot.TestEnv.put_env_restoring(:fleet_credentials, :role_tokens_dir, tmp)

    :ok
  end

  test "await_arch poste le verdict AU NOM DU JUGE (token de rôle écrase le système)" do
    step_run = %{
      repo: "fleet/poc",
      issue_number: 3,
      role: "consultant",
      decision: "redirect",
      comment_body: "Verdict du consultant — redirect"
    }

    assert {:ok, :awaiting_arch} =
             StepRunCompleter.await_arch(step_run,
               forge_client: TokenCaptureForge,
               forge_opts: [token: "system-token"]
             )

    # le token système de base est ÉCRASÉ par le token du rôle → auteur forge = Consultant (anti-masking).
    assert_received {:comment_token, "tok-consultant"}
  end

  test "complete : le comment signé du step_run est AU NOM DU RÔLE qui finit" do
    step_run = %{
      repo: "fleet/poc",
      issue_number: 1,
      role: "consultant",
      deliverable_opts: nil,
      step_run_sha: "brief-verdict",
      next_assignee: nil,
      comment_body: "Verdict du consultant — continue"
    }

    assert {:ok, :completed} =
             StepRunCompleter.complete(step_run,
               forge_client: TokenCaptureForge,
               forge_opts: [token: "system-token"]
             )

    assert_received {:comment_token, "tok-consultant"}
  end

  test "juge :promote (terminal) → stop du verrou PR signé JUGE, stop du verrou ISSUE signé PRODUCTEUR" do
    step_run = %{
      repo: "fleet/proj",
      issue_number: 42,
      role: "reviewer",
      pr_role: :judge,
      intent: :promote,
      next_assignee: nil,
      producer_branch: "lcars/issue-42-engineer"
    }

    assert {:ok, :promoted} =
             StepRunCompleter.complete_pr(step_run,
               forge_client: TokenCaptureForge,
               forge_opts: [token: "system-token"]
             )

    # verrou PR (7) : le JUGE (reviewer) qui vient de fermer la brique a démarré ce stopwatch
    # lui-même (son propre tour de review) → stop signé DE SON PROPRE token.
    assert_received {:stop_stopwatch, 7, "tok-reviewer"}

    # verrou ISSUE (42) : démarré par le PRODUCTEUR à `dispatch_issue`, persistant toute la review —
    # le stop DOIT rester signé PRODUCTEUR (engineer), JAMAIS le rôle du juge qui termine (sinon Gitea
    # refuse le stop — per-utilisateur — et le stopwatch de l'engineer fuit indéfiniment).
    assert_received {:stop_stopwatch, 42, "tok-engineer"}
  end
end

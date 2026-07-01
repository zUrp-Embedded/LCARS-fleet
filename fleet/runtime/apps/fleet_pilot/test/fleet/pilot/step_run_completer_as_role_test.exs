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
    def close_issue(_repo, _n, _opts), do: {:ok, :closed}
    def post_route(_repo, _n, _workflow_map_name, _step, _opts), do: {:ok, :posted}
  end

  setup %{tmp_dir: tmp} do
    # token de rôle consultant résoluble → `as_role("consultant")` doit l'injecter.
    File.write!(Path.join(tmp, "consultant.gitea_token"), "tok-consultant")
    prev = Application.get_env(:fleet_credentials, :role_tokens_dir)
    Application.put_env(:fleet_credentials, :role_tokens_dir, tmp)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:fleet_credentials, :role_tokens_dir, prev),
        else: Application.delete_env(:fleet_credentials, :role_tokens_dir)
    end)

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
end

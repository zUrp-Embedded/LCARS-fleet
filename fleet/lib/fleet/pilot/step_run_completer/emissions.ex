defmodule Fleet.Pilot.StepRunCompleter.Emissions do
  @moduledoc """
  Non-blocking side effects after a producer deliverable reaches the forge.

  The completion sequence discards every result from this module. Publication events
  release resident pod slots; engineer summaries add a role-signed issue trace. Failures
  are logged and never invalidate the published deliverable.
  """

  require Logger

  alias Fleet.Pilot.ForgeClient

  @doc """
  Emits `deliverable.published` for the producer pod after its commit and PR exist.

  Missing `pod_id` is a no-op. The pod's publish deadline backstops missed emissions.
  """
  @spec deliverable_published(map(), integer()) :: :ok | :noop
  def deliverable_published(step_run, pr) do
    case Map.get(step_run, :pod_id) do
      pod_id when is_binary(pod_id) ->
        _ =
          Fleet.EventRouter.Bus.safe_emit(
            :workflow,
            :"deliverable.published",
            [
              pod_id: pod_id,
              correlation_id: to_string(Map.fetch!(step_run, :issue_number)),
              payload: %{
                "repo" => Map.fetch!(step_run, :repo),
                "issue" => Map.fetch!(step_run, :issue_number),
                "pr" => pr
              }
            ],
            context: "StepRunCompleter: deliverable.published (slot-freeze release, non-fatal)"
          )

        :ok

      _ ->
        :noop
    end
  rescue
    # Payload construction is non-blocking too.
    e ->
      Logger.warning("StepRunCompleter: deliverable.published raised (#{inspect(e)})")
      :ok
  end

  @doc """
  Posts a non-empty producer summary on the issue using that producer's role token.

  The full note lives only on the issue; the PR opening may contain its pointer. Missing
  identity or post failure never invalidates completion.
  """
  @spec post_eng_summary(map(), keyword()) :: :ok | :noop
  def post_eng_summary(step_run, opts) do
    case Map.get(step_run, :eng_summary) do
      summary when is_binary(summary) and summary != "" ->
        forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
        forge_opts = Keyword.get(opts, :forge_opts, [])
        repo = Map.fetch!(step_run, :repo)
        n = Map.fetch!(step_run, :issue_number)
        role = Map.get(step_run, :role)

        with true <- role_present?(role, repo, n),
             {:ok, role_opts} <- ForgeClient.as_role(forge_opts, role),
             {:error, reason} <-
               forge.post_comment(
                 repo,
                 n,
                 "## 🔧 Note de l'#{role} (livrable)\n\n#{summary}",
                 role_opts
               ) do
          Logger.warning(
            "StepRunCompleter: #{repo}##{n} eng note NOT posted (#{inspect(reason)}) — " <>
              "ticket without the #{role} summary, no re-post rail (deliverable truth unaffected)"
          )
        end

        :ok

      _ ->
        :noop
    end
  end

  defp role_present?(role, _repo, _n) when is_binary(role) and role != "", do: true

  defp role_present?(_role, repo, n) do
    Logger.warning(
      "StepRunCompleter: #{repo}##{n} eng note NOT posted — the step_run carries no role, and " <>
        "the note is a role's VOICE posted with a role's TOKEN. Attributing it to a default " <>
        "would sign one producer's work as another's (deliverable truth unaffected)."
    )

    false
  end
end

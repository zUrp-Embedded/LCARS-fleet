defmodule Fleet.Pilot.StepRunCompleter.Emissions do
  @moduledoc """
  Side effects after producer publication: a slot-release event and a role-signed issue summary.

  Callers discard results. deliverable_published rescues exceptions; post_eng_summary
  does not. Missing role identity skips the summary, but only absent role names and
  returned post failures log here; token lookup errors return :ok without a local warning.
  Summary posts have no dedup signature and may repeat during completion replay.
  """

  require Logger

  alias Fleet.Forge.Client, as: ForgeClient

  @doc """
  Emits the publication event when pod_id is a binary; otherwise returns :noop.

  Event failures are logged and exceptions rescued. The pod's publish deadline can
  release a missed notification; it does not confirm publication by itself.
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
  Posts a nonempty issue summary using the producer's role token.
  The PR opening may link here before the summary is posted. Missing identity and
  returned post errors do not fail completion; exceptions, throws and exits can propagate.
  """
  @spec post_eng_summary(map(), keyword()) :: :ok | :noop
  def post_eng_summary(step_run, opts) do
    case Map.get(step_run, :eng_summary) do
      summary when is_binary(summary) and summary != "" ->
        forge = Keyword.get(opts, :forge_client, ForgeClient)
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

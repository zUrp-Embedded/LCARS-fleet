defmodule Fleet.Forge.Client.Actions do
  @moduledoc """
  Dispatches workflows on an existing ref and reads runs/jobs under /actions.
  The Gitea 1.26.1 API measured for this integration provides return_run_details=true to
  identify a dispatch immediately, head_sha filtering on runs, and logs by job (no run-log
  endpoint in that instance's schema). Keep these details when changing the transport.

  Probe workflow/context names must stay outside the configured required-check pattern CI / *.
  This module does not enforce naming or branch protection; workflow_dispatch alone is not
  established as suppressing commit statuses. A renamed probe can become a required check.
  """

  import Fleet.Forge.Client.Transport, only: [resolve_config: 1, http_get: 2, http_post: 3]
  import Fleet.Forge.Client.UrlSafe, only: [encode_repo: 1, encode_seg: 1]

  require Logger

  @typedoc """
  Trackable run id. Ignore run_url/html_url: their forge-internal host may be unusable by a
  browser. Callers construct links from the base URL appropriate to their destination.
  """
  @type run_ref :: %{run_id: pos_integer()}

  @doc """
  Dispatches a workflow filename (e.g. probe-test-relevance.yml) on ref, requesting run details
  to avoid guessing among concurrent runs on the same head. Inputs require binary values;
  invalid values return input_not_a_string before config/HTTP. Keys and ref syntax are not checked.
  A positive integer workflow_run_id returns {:ok, %{run_id: id}}. Other 2xx bodies, including
  empty 204, log and return dispatch_untrackable. A dispatch may already have occurred: this
  error neither proves a runner started nor makes a retry safe from duplicate dispatch.
  """
  @spec dispatch_workflow(
          String.t(),
          String.t(),
          String.t(),
          %{optional(String.t()) => String.t()},
          keyword()
        ) ::
          {:ok, run_ref()} | {:error, term()}
  def dispatch_workflow(repo, workflow_file, ref, inputs \\ %{}, opts \\ [])
      when is_binary(repo) and is_binary(workflow_file) and is_binary(ref) and is_map(inputs) do
    with :ok <- validate_inputs(inputs),
         {:ok, config} <- resolve_config(opts) do
      path =
        "/repos/#{encode_repo(repo)}/actions/workflows/#{encode_seg(workflow_file)}" <>
          "/dispatches?return_run_details=true"

      case http_post(config, path, %{"ref" => ref, "inputs" => inputs}) do
        # `run_url` et `html_url` sont dans la reponse et ne sont PAS lus — cf. `t:run_ref/0`.
        {:ok, %{"workflow_run_id" => id}} when is_integer(id) and id > 0 ->
          {:ok, %{run_id: id}}

        # HTTP success without an id is untrackable. The historical log overstates runner activity;
        # no job state is read here, and the side effect may be queued or otherwise uncertain.
        {:ok, body} ->
          Logger.error(
            "ForgeActions: #{repo} dispatched #{workflow_file} on #{ref} but the forge returned NO " <>
              "run details (#{inspect(body)}) — a runner is working and nothing can read its result. " <>
              "`return_run_details=true` was sent; an instance older than 1.26.1 or a proxy stripping " <>
              "the query would explain it."
          )

          {:error, {:dispatch_untrackable, workflow_file}}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Reads a raw run response without shape validation. Consumers must distinguish lifecycle
  status from conclusion: absent conclusion alone does not distinguish unfinished from failed.
  """
  @spec run(String.t(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(repo, run_id, opts \\ []) when is_binary(repo) and is_integer(run_id) do
    with {:ok, config} <- resolve_config(opts) do
      http_get(config, "/repos/#{encode_repo(repo)}/actions/runs/#{run_id}")
    end
  end

  @doc """
  Reads one server-ordered page filtered by head_sha plus caller filters, without pagination
  or local filtering. Expects workflow_runs as a list; total_count is optional and only warns
  when greater than the page length. The returned list does not carry a completeness flag.
  event: workflow_dispatch excludes push-triggered runs but also includes manual dispatches.
  """
  @spec runs_for_sha(String.t(), String.t(), keyword(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def runs_for_sha(repo, head_sha, filters \\ [], opts \\ [])
      when is_binary(repo) and is_binary(head_sha) and is_list(filters) do
    with {:ok, config} <- resolve_config(opts) do
      query =
        [
          {"head_sha", head_sha}
          | Enum.map(filters, fn {k, v} -> {to_string(k), to_string(v)} end)
        ]
        |> URI.encode_query()

      # Keep unexpected envelope shape distinct from a successful empty list.
      case http_get(config, "/repos/#{encode_repo(repo)}/actions/runs?#{query}") do
        {:ok, %{"workflow_runs" => runs} = body} when is_list(runs) ->
          warn_if_truncated(repo, head_sha, body, runs)
          {:ok, runs}

        {:ok, other} ->
          {:error, {:unexpected_runs_shape, other}}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Cherche un run workflow_dispatch dont path contient probe- sur la page retournée pour cette tête.
  Ne vérifie ni exécution, ni résultat, ni acteur : le compte du rail ne distingue pas les juges.
  false peut manquer une sonde hors page ; une erreur de lecture reste une erreur.
  Usage prévu : annotation du verdict, sans faire de la sonde une condition d'avancement.
  """
  @spec probed?(String.t(), String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def probed?(repo, head_sha, opts \\ []) when is_binary(repo) and is_binary(head_sha) do
    case runs_for_sha(repo, head_sha, [event: "workflow_dispatch"], opts) do
      {:ok, runs} -> {:ok, Enum.any?(runs, &probe_run?/1)}
      {:error, _} = err -> err
    end
  end

  # Substring heuristic, not a filename-prefix check or proof that a judge initiated the run.
  defp probe_run?(%{"path" => path}) when is_binary(path), do: String.contains?(path, "probe-")
  defp probe_run?(_), do: false

  @doc """
  Reads one jobs page then each job's logs sequentially, concatenating named sections.
  Returned per-job errors become unreadable sections; missing ids get their own section.
  Exceptions/malformed job fields can still raise. No jobs returns {:ok, ""} without diagnosing
  the runner. Job pagination and total_count are not checked, so the log may be partial.
  """
  @spec run_logs(String.t(), pos_integer(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run_logs(repo, run_id, opts \\ []) when is_binary(repo) and is_integer(run_id) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, jobs} <- run_jobs(config, repo, run_id) do
      {:ok, Enum.map_join(jobs, "\n", &job_section(config, repo, &1))}
    end
  end

  # Warning only: a caller can still mistake a run beyond the page for an absent run.
  defp warn_if_truncated(repo, head_sha, body, runs) do
    total = Map.get(body, "total_count")

    if is_integer(total) and total > length(runs) do
      Logger.warning(
        "ForgeActions: #{repo} head #{String.slice(head_sha, 0, 8)} — #{length(runs)} run(s) read " <>
          "of #{total} announced. The answer is built on a PARTIAL page; a run beyond it is " <>
          "indistinguishable from an absent one."
      )
    end

    :ok
  end

  @doc """
  Returns the raw jobs list from one response. Consumers inspect status, requested labels
  and runner identity to diagnose waiting work; field shapes and completeness are not validated.
  """
  @spec jobs(String.t(), pos_integer(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def jobs(repo, run_id, opts \\ []) when is_binary(repo) and is_integer(run_id) do
    with {:ok, config} <- resolve_config(opts), do: run_jobs(config, repo, run_id)
  end

  defp run_jobs(config, repo, run_id) do
    # Meme enveloppe declaree (`ActionWorkflowJobsResponse`), meme refus d'un repli complaisant.
    case http_get(config, "/repos/#{encode_repo(repo)}/actions/runs/#{run_id}/jobs") do
      {:ok, %{"jobs" => jobs}} when is_list(jobs) -> {:ok, jobs}
      {:ok, other} -> {:error, {:unexpected_jobs_shape, other}}
      {:error, _} = err -> err
    end
  end

  defp job_section(config, repo, job) do
    id = Map.get(job, "id")
    name = Map.get(job, "name", "job")

    body =
      case id && http_get(config, "/repos/#{encode_repo(repo)}/actions/jobs/#{id}/logs") do
        {:ok, text} when is_binary(text) -> text
        {:ok, other} -> inspect(other)
        {:error, reason} -> "<< logs unreadable: #{inspect(reason)} >>"
        nil -> "<< job carries no id >>"
      end

    "===== job #{name} (#{id}) =====\n" <> body
  end

  defp validate_inputs(inputs) do
    Enum.find_value(inputs, :ok, fn
      {_k, v} when is_binary(v) -> nil
      {k, v} -> {:error, {:input_not_a_string, k, v}}
    end)
  end
end

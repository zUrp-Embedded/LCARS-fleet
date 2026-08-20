defmodule Fleet.Forge.Client.Actions do
  @moduledoc """
  Triggers a workflow OUTSIDE a push, and reads back what it did — sub-domain of
  `Fleet.Forge.Client`, on the pattern of `Fleet.Forge.Client.Jury`.

  Self-contained concern: it touches only `/repos/{o}/{r}/actions/…` and calls no other forge op.
  Before this module, **nothing in the whole client touched `/actions/`** — `files.ex`, `jury.ex`,
  `repo.ex`, `transport.ex` and `url_safe.ex` were checked one by one. The rail could observe a CI
  run that a push had started, and could not ASK for one.

  ## Why the rail needs to ask

  A judge's verdict on a deliverable is an opinion until something measures it. The measurement this
  fleet wants — *does the suite actually catch a defect in the code it claims to cover* — is not a
  property of a push: it is a question asked about a head that already exists, and the answer must
  be produced by running something. `workflow_dispatch` is the only door in the forge that opens
  without a commit, and this module is that door.

  ## The three API facts, MEASURED on the bench (Gitea 1.26.1, swagger of a live instance)

  1. **`return_run_details=true` on the dispatch** turns `204 No Content` into `200 + RunDetails`
     (`workflow_run_id`, `run_url`, `html_url`). The rail therefore names its run IMMEDIATELY.
     Without it, following the run would mean listing runs and guessing which is ours — a guess with
     a real race the moment two judges probe the same head. This module always sends the parameter
     and REFUSES a 204 rather than return a success it cannot follow (see `dispatch_workflow/5`).

  2. **There is no `/runs/{id}/logs`.** Verified by ABSENCE from the swagger, not inferred from a
     404: the logs of a run are the concatenation of the logs of its JOBS
     (`/runs/{run}/jobs` → `/jobs/{job_id}/logs`). A caller that writes the natural URL gets a 404
     and reads it as "no logs", which is a different fact from "logs live one level down".

  3. **`GET /actions/runs` filters on `head_sha`** (as well as `event`, `branch`, `status`,
     `actor`). That filter is what makes a probe VERIFIABLE after the fact: the rail can ask "was
     this head ever probed?" without holding any local state — the forge is the record.

  ## The naming guard, and what is NOT established about it

  Probe workflows are named `probe-*`, never `CI*`. The reason is mechanical: `main`'s protection
  requires `status_check_contexts: ["CI / *"]` (`onboard.ex`), and a context named `probe-… / …`
  does not match that glob — so a probe cannot become a REQUIRED check and cannot block a merge.
  That would be the opposite of the intent: it would remove the CI from the loop while claiming to
  augment it.

  ⚠ **What is established is that the NAME protects. It is NOT established that a
  `workflow_dispatch` creates no commit status at all** — that would make the protection come from
  the TRIGGER TYPE, and the name would merely be good practice. Until someone dispatches a workflow
  deliberately named `CI / probe` and looks, treat the name as **the only guard**, and a careless
  rename as a way to turn a probe into a wall.
  """

  import Fleet.Forge.Client.Transport, only: [resolve_config: 1, http_get: 2, http_post: 3]
  import Fleet.Forge.Client.UrlSafe, only: [encode_repo: 1, encode_seg: 1]

  require Logger

  @typedoc """
  What a dispatch hands back once it is trackable: the run's id, and NOTHING ELSE.

  ⚠ **Les URL rendues par la forge (`run_url`, `html_url`) sont deliberement ignorees**, et ce n'est
  pas une simplification — c'est un refus documente par le depot, que le contrat
  `forge.payload_fields_read` a rappele a ce module le jour de son ecriture :

  > *une URL fournie par la forge porte l'hote qui a REPONDU, qui n'est pas necessairement celui
  > qu'on adresse — le conteneur atteint `http://forge:3000` la ou un navigateur atteint un port
  > publie, donc la transmettre telle quelle propagerait le mauvais hote.*

  Un appelant qui veut un lien le construit depuis le `base_url` qu'il utilise VRAIMENT. L'id, lui,
  est un fait sans hote.
  """
  @type run_ref :: %{run_id: pos_integer()}

  @doc """
  Dispatches `workflow_file` on `ref` with `inputs`, and returns the run it started.

  `workflow_file` is the FILE NAME as it lives in `.gitea/workflows/`
  (`"probe-test-relevance.yml"`), not a display name — the forge keys the endpoint on the file.
  `ref` is a git ref (`"refs/heads/main"`, or a branch name). `inputs` is the workflow's
  `workflow_dispatch.inputs`, and the forge's schema types it as an object of STRINGS.

  ## Non-string inputs are refused HERE, before the wire

  `{:error, {:input_not_a_string, key, value}}`. The forge would answer 422 with a body naming the
  schema rather than the key, and a caller that passed an integer by accident would go looking at
  its workflow file. Refusing at the boundary names the actual mistake, and costs one guard.

  ## A 204 is an ERROR here, and that is deliberate

  `204` means the forge ignored `return_run_details` (older instance, proxy stripping the query).
  The run HAS started — a runner is burning — but nothing names it, so no fact can ever be read
  back from it. Returning `:ok` there would report a measurement that can never be collected;
  `{:error, {:dispatch_untrackable, workflow_file}}` says the true thing, and says it loudly
  because the side effect happened anyway.
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

        # 2xx WITHOUT the details: `request/4` flattens 204 to `{:ok, body}` with an empty body, and
        # a forge that ignored the parameter lands here too. Same fact either way — it ran, we
        # cannot follow it.
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
  Reads one run: its status, its conclusion, and the head it ran against.

  `status` is the LIFECYCLE (`"waiting"`, `"running"`, `"success"`, `"failure"`…) and `conclusion`
  is the VERDICT once there is one. They are two fields and not one because a run that has not
  finished has no conclusion — a caller that reads only `conclusion` cannot tell "not yet" from
  "not good", which is the same conflation the merge rail paid for on Gitea's 405.
  """
  @spec run(String.t(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(repo, run_id, opts \\ []) when is_binary(repo) and is_integer(run_id) do
    with {:ok, config} <- resolve_config(opts) do
      http_get(config, "/repos/#{encode_repo(repo)}/actions/runs/#{run_id}")
    end
  end

  @doc """
  Every run recorded against `head_sha`, most recent first as the forge orders them.

  THE POST-HOC VERIFICATION OF A PROBE, and the reason the rail needs no state of its own: "did a
  judge measure this head?" is answered by the forge, which holds the record. Filtering
  client-side on a listing would be the same question asked worse — the endpoint takes `head_sha`
  natively (measured, 1.26.1).

  Pass `event: "workflow_dispatch"` in `filters` to keep only the runs somebody ASKED for, i.e.
  exclude the push-driven CI of the same head.
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

      # ENVELOPE, ET RIEN D'AUTRE. Le contrat declare `ActionWorkflowRunsResponse`
      # (`{total_count, workflow_runs}`) — meme non-uniformite que celle pour laquelle `paginate/4`
      # porte son `unwrap`. Accepter AUSSI un tableau nu serait accepter une forme que la forge ne
      # promet pas, et surtout MASQUER le jour ou l'enveloppe change : le repli rendrait `[]`, et
      # « aucun run » est justement la seule reponse que cette fonction ne doit jamais inventer.
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
  The logs of a run, job by job, concatenated with a header naming each job.

  **The logs of a RUN do not exist as an endpoint** — see the moduledoc. This walks
  `/runs/{run}/jobs` then `/jobs/{job_id}/logs`, which is why a run with no job yet returns
  `{:ok, ""}` rather than an error: "the runner has not picked it up" is not a failure, and a
  caller polling for a result must be able to tell those apart.

  A job whose logs cannot be read does NOT sink the whole read: its section says so in place of its
  content. A partial log that names its hole beats an error that discards the jobs that did answer.
  """
  @spec run_logs(String.t(), pos_integer(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run_logs(repo, run_id, opts \\ []) when is_binary(repo) and is_integer(run_id) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, jobs} <- run_jobs(config, repo, run_id) do
      {:ok, Enum.map_join(jobs, "\n", &job_section(config, repo, &1))}
    end
  end

  # `total_count` EST DANS L'ENVELOPPE, DONC LA TRONCATURE EST DICIBLE. Sans ce garde-fou, une tete
  # dont la page 1 est pleine rendrait « pas de sonde » alors que la sonde est en page 2 — un
  # plafond silencieux qui se lit exactement comme une absence. On ne pagine pas ici (la question
  # est « existe-t-il », pas « lister tout »), on DIT qu'on n'a pas tout vu.
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

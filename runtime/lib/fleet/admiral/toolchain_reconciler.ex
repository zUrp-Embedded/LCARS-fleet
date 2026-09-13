defmodule Fleet.Admiral.ToolchainReconciler do
  @moduledoc """
  Polls the toolchain branch against a local applied marker, then drains waiting
  issues associated with closed PRs. PeriodicCheck owns scheduling; manual checks
  share the pass. Convergence and label/comment writes are not transactional.

  toolchain.applied lives under LCARS_TOOLCHAIN_RUN_STATE, default /run/lcars/toolchain.
  Deployment must keep this container-scoped (normally tmpfs): a marker surviving
  rebuild can falsely claim that the new /usr is converged. This module does not
  enforce mount type. Marker reads do not inspect installed packages.

  The default converger opens the privileged UNIX socket and sends no command or SHA;
  the service selects its own branch head. Approval/protection enforcement belongs
  downstream, not to this call. Its reported applied SHA is recorded after success.

  Config: admiral_toolchain_reconcile_interval_ms defaults to 60_000;
  admiral_forge_client supplies reads, toolchain_converger supplies the operation.
  Socket path: toolchain_socket, then LCARS_TOOLCHAIN_SOCKET, then
  /run/lcars/privileged/toolchain.sock.
  """

  use GenServer

  require Logger

  alias Fleet.Forge.Payload
  alias Fleet.PeriodicCheck

  @default_interval_ms 60_000
  @default_run_state "/run/lcars/toolchain"

  # Separate local connection timeout (5 s) from package convergence response (30 min).
  @socket_connect_ms 5_000
  @converge_timeout_ms 30 * 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: PeriodicCheck.start_link(__MODULE__, opts)

  @doc """
  Runs an immediate check without re-arming the timer. Returns converged/up_to_date
  or a returned error. GenServer.call uses its default timeout, which can expire
  long before the privileged service's 30-minute response timeout; it does not cancel the pass.
  """
  @spec check_now(GenServer.server()) ::
          {:ok, :converged, String.t()} | {:ok, :up_to_date} | {:error, term()}
  def check_now(server \\ __MODULE__), do: GenServer.call(server, :check_now)

  @doc """
  Reads and trims the marker; absent, unreadable or empty returns nil and prompts
  convergence on the next readable head. A present string is not verified against /usr.
  """
  @spec applied_sha() :: String.t() | nil
  def applied_sha do
    case File.read(marker_path()) do
      {:ok, sha} -> String.trim(sha) |> nil_if_empty()
      {:error, _} -> nil
    end
  end

  @impl GenServer
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms) || config_interval(),
      repo: Keyword.get(opts, :repo),
      branch: Keyword.get(opts, :branch),
      last_result: nil,
      rejected_sha: nil
    }

    _ = PeriodicCheck.schedule(:reconcile, state.interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:reconcile, state), do: PeriodicCheck.tick(state, :reconcile, &do_check/1)
  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:check_now, _from, state),
    do: PeriodicCheck.check_now(state, &do_check/1, & &1.last_result)

  # Exceptions become a last_result value and preserve the prior rejected SHA.
  # This wrapper does not catch throws/exits.
  defp do_check(state) do
    result =
      try do
        reconcile_pass(state)
      rescue
        e ->
          Logger.error("ToolchainReconciler: passe en échec — #{Exception.message(e)}")
          {{:error, {:raised, Exception.message(e)}}, state.rejected_sha}
      end

    %{state | last_result: elem(result, 0), rejected_sha: elem(result, 1)}
  end

  # Cache the head rejected by {:converger_failed, 2, _} until a different head is read.
  # The cache is process-local. Default socket FAIL responses use converger_refused
  # and do not trigger this freeze; the rc=2 tests inject the older error shape.
  defp reconcile_pass(state) do
    repo = state.repo || Fleet.Toolchain.ops_repo()
    branch = state.branch || Fleet.Toolchain.branch()

    {result, rejected} =
      case forge().branch_head(repo, branch, []) do
        {:ok, head} when head == state.rejected_sha ->
          Logger.debug(
            "ToolchainReconciler: head #{head} déjà REFUSÉ (document faux) — gelé jusqu'à un " <>
              "nouveau merge"
          )

          {{:error, {:manifest_rejected, head}}, head}

        {:ok, head} ->
          case converge_if_moved(head) do
            {:error, {:converger_failed, 2, _out}} = err ->
              Logger.error(
                "ToolchainReconciler: le convergeur a JUGÉ LE DOCUMENT FAUX (rc=2) à #{head} — " <>
                  "gelé : aucun rejeu ne répare un manifeste refusé, seul un nouveau merge dégèle"
              )

              {err, head}

            other ->
              {other, nil}
          end

        {:error, reason} ->
          {unreachable(reason), state.rejected_sha}
      end

    drain_pass(repo, branch, result)
    {result, rejected}
  end

  # Closed-without-merge PRs leave the branch unchanged, so drain them separately.
  # Merged PRs require this pass's successful branch result. Issue labels carry the
  # waiting state; failures may leave partial effects for a later tick.
  defp drain_pass(repo, branch, branch_result) do
    # Request server-side base filtering, then recheck the base locally.
    case forge().list_pulls_for_base(repo, branch, []) do
      {:ok, prs} ->
        Enum.each(prs, &maybe_drain(&1, branch, branch_result))

      {:error, reason} ->
        Logger.warning(
          "ToolchainReconciler: passe de drain — PR illisibles (#{inspect(reason)}), " <>
            "les verrous restent posés, le tick suivant retentera"
        )
    end
  rescue
    e ->
      Logger.warning("ToolchainReconciler: passe de drain en échec — #{Exception.message(e)}")
  end

  defp maybe_drain(pr, branch, branch_result) do
    with true <- Payload.base_ref(pr) == branch,
         {:ok, item_repo, item_issue} <- Fleet.Toolchain.parse_workitem_marker(pr["body"]) do
      drain_outcome(pr_outcome(pr), {item_repo, item_issue, pr}, branch_result)
    else
      _ -> :ok
    end
  end

  defp drain_outcome(:open, _work_item, _branch_result), do: :ok

  defp drain_outcome(:merged, {item_repo, item_issue, pr}, branch_result) do
    if applied?(branch_result),
      do: drain(item_repo, item_issue, pr, :merged),
      else: :ok
  end

  defp drain_outcome(:refused, {item_repo, item_issue, pr}, _branch_result),
    do: drain(item_repo, item_issue, pr, :refused)

  defp pr_outcome(pr) do
    cond do
      Payload.merged?(pr) -> :merged
      pr["state"] == "closed" -> :refused
      true -> :open
    end
  end

  defp applied?({:ok, :up_to_date}), do: true
  defp applied?({:ok, :converged, _}), do: true
  defp applied?(_), do: false

  defp drain(repo, issue, pr, why) do
    lock = Fleet.Toolchain.waiting_label()

    case forge().get_issue(repo, issue, []) do
      {:ok, payload} ->
        if lock in Payload.label_names(payload) do
          do_drain(repo, issue, pr, why, lock)
        else
          :ok
        end

      {:error, reason} ->
        Logger.warning(
          "ToolchainReconciler: drain — issue #{repo}##{issue} illisible (#{inspect(reason)}), " <>
            "le verrou reste, le tick suivant retentera"
        )
    end
  end

  defp do_drain(repo, issue, pr, why, lock) do
    case forge().remove_label(repo, issue, lock, []) do
      {:ok, _} ->
        # Removing the wait label makes the issue eligible for normal redispatch checks.
        # Comment errors are ignored after removal, so that explanation may never be retried.
        _ = forge().post_comment(repo, issue, drain_comment(why, pr), [])

        Logger.info(
          "ToolchainReconciler: work-item #{repo}##{issue} drainé (#{why}, PR ##{pr["number"]})"
        )

      {:error, reason} ->
        Logger.warning(
          "ToolchainReconciler: drain — verrou de #{repo}##{issue} non retiré " <>
            "(#{inspect(reason)}), le tick suivant retentera"
        )
    end
  end

  defp drain_comment(:merged, pr) do
    "Outillage APPLIQUÉ : la PR ##{pr["number"]} est mergée et le conteneur a convergé. " <>
      "Ce ticket redevient dispatchable."
  end

  defp drain_comment(:refused, pr) do
    "Demande d'outillage REFUSÉE : la PR ##{pr["number"]} a été fermée sans merge. " <>
      "Ce ticket redevient dispatchable — à l'humain du projet de décider la suite " <>
      "(autre approche, ou re-demande amendée)."
  end

  defp converge_if_moved(head) do
    case applied_sha() do
      ^head ->
        {:ok, :up_to_date}

      previous ->
        Logger.info(
          "ToolchainReconciler: écart détecté (appliqué=#{previous || "aucun"} head=#{head}) — convergence"
        )

        run_converger(head)
    end
  end

  # Record the SHA returned by the service: its head resolution can race ours.
  # Bare :ok uses the sampled head for legacy stubs. Marker write errors only warn;
  # convergence still succeeds and can drain issues, then repeat next tick.
  defp run_converger(head) do
    case converger().(head, []) do
      {:ok, applied} when is_binary(applied) and applied != "" ->
        if applied != head do
          Logger.info(
            "ToolchainReconciler: la branche a avancé entre la lecture (#{head}) et la " <>
              "convergence (#{applied}) — c'est l'état APPLIQUÉ qui est noté."
          )
        end

        _ = write_marker(applied)
        {:ok, :converged, applied}

      :ok ->
        _ = write_marker(head)
        {:ok, :converged, head}

      {:error, reason} ->
        Logger.error(
          "ToolchainReconciler: le convergeur a REFUSÉ #{head} (#{inspect(reason)}) — le SHA " <>
            "appliqué reste inchangé, la passe suivante réessaiera. L'état déclaré n'est PAS appliqué."
        )

        {:error, reason}
    end
  end

  # Connecting is the request; privileged policy is enforced by the service.
  defp default_converger(_head, _opts) do
    path =
      Application.get_env(:lcars_fleet, :toolchain_socket) ||
        System.get_env("LCARS_TOOLCHAIN_SOCKET") ||
        "/run/lcars/privileged/toolchain.sock"

    opts = [:binary, packet: :line, active: false]

    case :gen_tcp.connect({:local, path}, 0, opts, @socket_connect_ms) do
      {:ok, sock} ->
        try do
          read_converge_answer(sock, path)
        after
          :gen_tcp.close(sock)
        end

      {:error, reason} ->
        # Connection failure differs from an explicit service refusal.
        {:error, {:privileged_unreachable, path, reason}}
    end
  end

  # Send no bytes: the socket selects the operation; callers supply no executable argument.
  defp read_converge_answer(sock, path) do
    case :gen_tcp.recv(sock, 0, @converge_timeout_ms) do
      {:ok, line} ->
        case String.trim_trailing(line, "\n") do
          "OK:" <> sha when byte_size(sha) > 0 ->
            {:ok, sha}

          "FAIL:" <> cause ->
            {:error, {:converger_refused, cause}}

          other ->
            {:error, {:converger_mute, path, other}}
        end

      {:error, reason} ->
        {:error, {:converger_mute, path, reason}}
    end
  end

  defp unreachable(reason) do
    Logger.warning(
      "ToolchainReconciler: branche illisible (#{inspect(reason)}) — AUCUNE conclusion tirée, " <>
        "la passe suivante réessaiera. Ce n'est pas « à jour »."
    )

    {:error, {:branch_unreadable, reason}}
  end

  defp marker_path do
    dir =
      case System.get_env("LCARS_TOOLCHAIN_RUN_STATE") do
        d when is_binary(d) and d != "" -> d
        _unset -> @default_run_state
      end

    Path.join(dir, "toolchain.applied")
  end

  defp write_marker(head) do
    path = marker_path()
    _ = File.mkdir_p(Path.dirname(path))

    case File.write(path, head <> "\n") do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ToolchainReconciler: convergé sur #{head} mais le marqueur est INÉCRIVABLE " <>
            "(#{inspect(reason)} sur #{path}) — la prochaine passe reconvergera. Le répertoire " <>
            "est posé par le provisioning (25-directories)."
        )

        :ok
    end
  end

  defp config_interval,
    do:
      Application.get_env(
        :lcars_fleet,
        :admiral_toolchain_reconcile_interval_ms,
        @default_interval_ms
      )

  # Domain-prefixed forge seam avoids colliding with unrelated per-call forge_client options.
  defp forge, do: Application.get_env(:lcars_fleet, :admiral_forge_client, Fleet.Forge.Client)

  defp converger,
    do:
      Application.get_env(:lcars_fleet, :toolchain_converger, &__MODULE__.default_converger_fun/2)

  @doc false
  @spec default_converger_fun(String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error,
             {:converger_refused, binary()}
             | {:converger_mute, Path.t(), term()}
             | {:privileged_unreachable, Path.t(), term()}}
  def default_converger_fun(head, opts), do: default_converger(head, opts)

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s
end

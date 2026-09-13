defmodule Fleet.Test.AuthorityDouble do
  @moduledoc """
  Unix-socket authority double backed by token fixture files. Each request resolves
  `:credentials_role_tokens_dir` again (fallback `/opt/lcars/var/tokens`) and reads
  `<account>.gitea_token`. No Forge membership or master-authority checks are performed;
  use `force_fail/1` to exercise those refusal responses.

  One account line yields one token or `FAIL:<cause>` line, then the connection closes.
  The reader removes trailing LF characters only; it does not trim account whitespace
  or CR. This is not a complete reproduction of the service's input normalization.
  """

  # Keep the double independent of RoleToken so tests cross the actual socket protocol.
  use Boundary, deps: [], exports: []
  use GenServer

  @name __MODULE__
  # authority_double.bats compares this copied pattern with the service's ROLE_RX.
  @role_rx ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/

  @doc """
  Starts the named double and returns its socket path. Initialization sets
  `:credentials_authority_socket`; repeated calls reuse the process without resetting
  that configuration. The suite starts it once from test_helper.exs.
  """
  @spec start() :: Path.t()
  def start do
    case GenServer.start(__MODULE__, [], name: @name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    socket_path()
  end

  @doc "Le chemin de la socket servie."
  @spec socket_path() :: Path.t()
  def socket_path, do: GenServer.call(@name, :socket_path)

  @doc """
  Forces subsequent responses to `FAIL:<cause>` until reset with nil.
  This setting is shared by all tests using the double.
  """
  @spec force_fail(atom() | nil) :: :ok
  def force_fail(cause), do: GenServer.call(@name, {:force_fail, cause})

  @impl true
  def init(_) do
    path =
      Path.join(
        System.tmp_dir!(),
        # OS pid separates concurrent VMs; the counter separates listeners within a VM.
        "lcars-authority-double-#{System.pid()}-#{System.unique_integer([:positive])}.sock"
      )

    _ = File.rm(path)

    # AF_UNIX uses {:local, path} with port 0.
    {:ok, listen} =
      :gen_tcp.listen(0, [
        {:ifaddr, {:local, path}},
        :binary,
        packet: :line,
        active: false,
        reuseaddr: true
      ])

    Application.put_env(:lcars_fleet, :credentials_authority_socket, path)
    parent = self()
    {:ok, _} = Task.start_link(fn -> accept_loop(listen, parent) end)

    {:ok, %{path: path, listen: listen, force: nil}}
  end

  @impl true
  def handle_call(:socket_path, _from, state), do: {:reply, state.path, state}
  def handle_call({:force_fail, cause}, _from, state), do: {:reply, :ok, %{state | force: cause}}
  def handle_call(:force, _from, state), do: {:reply, state.force, state}

  @impl true
  def terminate(_reason, state) do
    _ = :gen_tcp.close(state.listen)
    _ = File.rm(state.path)
    :ok
  end

  defp accept_loop(listen, parent) do
    case :gen_tcp.accept(listen) do
      {:ok, conn} ->
        # A client that connects without writing must not block other clients.
        {:ok, _} = Task.start(fn -> serve(conn, parent) end)
        accept_loop(listen, parent)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        accept_loop(listen, parent)
    end
  end

  defp serve(conn, parent) do
    answer =
      case :gen_tcp.recv(conn, 0, 5_000) do
        {:ok, line} -> answer_for(String.trim_trailing(line, "\n"), parent)
        {:error, _} -> "FAIL:bad_role"
      end

    _ = :gen_tcp.send(conn, answer <> "\n")
    :gen_tcp.close(conn)
  end

  defp answer_for(account, parent) do
    case GenServer.call(parent, :force) do
      nil -> resolve(account)
      cause -> "FAIL:#{cause}"
    end
  end

  defp resolve(account) do
    if Regex.match?(@role_rx, account) do
      dir =
        Application.get_env(:lcars_fleet, :credentials_role_tokens_dir) || "/opt/lcars/var/tokens"

      token_or_fail(File.read(Path.join(dir, "#{account}.gitea_token")))
    else
      "FAIL:bad_role"
    end
  end

  # An empty token file is a refusal, not an empty credential.
  defp token_or_fail({:ok, raw}) do
    case String.trim(raw) do
      "" -> "FAIL:no_role_token"
      token -> token
    end
  end

  defp token_or_fail({:error, _}), do: "FAIL:no_role_token"
end

defmodule Fleet.Test.AuthorityDouble do
  @moduledoc """
  Le double du service d'autorité, pour la suite — `roles.sock` sans `catalogue-executor.py`.

  ## Pourquoi il existe, et pourquoi il lit des fichiers

  `Fleet.Credentials.RoleToken.token/1` ne lit plus `<dir>/<compte>.gitea_token` : il le DEMANDE à
  `roles.sock`. Une centaine de témoins, eux, posent leurs jetons en écrivant ces fichiers dans un
  `tmp` et en pointant `:credentials_role_tokens_dir` dessus.

  Ce double sert exactement ce que le vrai service sert, DEPUIS LE MÊME ENDROIT — il résout le
  répertoire à CHAQUE requête, via la même clé de config que les témoins posent déjà. Aucun fichier
  de test n'a donc eu à changer de fixture : ce qui a changé est QUI ouvre le fichier, et c'était
  tout l'objet du chantier.

  ⚠ **C'est un double, pas une simulation de la forge.** Le vrai service demande d'abord à la forge
  si le demandeur appartient à l'équipe `humans` (`FAIL:not_a_worker`), et sait dire qu'il n'a pas
  d'autorité (`FAIL:no_authority`). Ici il n'y a ni forge ni master : ces causes-là se jouent par
  `force_fail/1`, et un témoin qui veut les prouver le dit explicitement. Un double qui rendrait
  toujours un jeton prouverait le chemin heureux et rien d'autre.

  ## Le protocole, recopié depuis `catalogue-executor.py:serve_role_token`

      -> <compte>\\n
      <- <jeton>\\n   |   FAIL:<cause>\\n

  Une ligne, une réponse, la connexion se ferme. `rstrip("\\r\\n")` et pas `strip()` : le vrai
  service a payé ce défaut une fois — `.strip()` normalisait le fil et faisait passer un nom mal
  cadré pour un nom valide.
  """

  # Aucune dépendance Fleet : ce double parle le protocole du service, pas l'API du runtime. C'est
  # ce qui le rend capable de prouver que le BEAM passe bien par la socket — un double qui appellerait
  # `RoleToken` prouverait que `RoleToken` s'appelle lui-même.
  use Boundary, deps: [], exports: []
  use GenServer

  @name __MODULE__
  # Le même que le service (`ROLE_RX`). Recopié, donc comparé : `authority_double.bats` épingle
  # l'égalité des deux motifs. Une copie que personne ne vérifie n'est pas une source de vérité.
  @role_rx ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/

  @doc """
  Démarre le double, pose `:credentials_authority_socket` sur sa socket, et rend son chemin.

  Idempotent : un second appel rend la socket déjà en service. La suite l'appelle une fois depuis
  `test_helper.exs` — le répertoire servi étant résolu par requête, un seul process suffit pour
  tous les témoins, y compris ceux qui changent de `tmp` entre deux.
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
  Force la prochaine réponse (et les suivantes) à une cause donnée, ou rétablit le service normal
  avec `nil`. C'est par là que se prouvent les causes qu'un double sans forge ne peut pas produire.
  """
  @spec force_fail(atom() | nil) :: :ok
  def force_fail(cause), do: GenServer.call(@name, {:force_fail, cause})

  @impl true
  def init(_) do
    path =
      Path.join(
        System.tmp_dir!(),
        "lcars-authority-double-#{System.unique_integer([:positive])}.sock"
      )

    _ = File.rm(path)

    # ⚠ `{:local, path}` AVEC `0` EN PORT : la forme qu'Erlang exige pour AF_UNIX. Le zéro n'est pas
    # un port — même idiome que le vrai listener côté BEAM.
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
        # ⚠ SERVI DANS UNE TÂCHE À PART, ET CE N'EST PAS DU CONFORT. Servi dans la boucle, un client
        # qui ouvre sans écrire bloquerait tous les autres — et le témoin qui en souffrirait ne
        # serait pas celui qui l'a ouvert. Un double qui fait échouer un témoin voisin est pire
        # qu'un double absent : il déplace le diagnostic.
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
      dir = Application.get_env(:lcars_fleet, :credentials_role_tokens_dir) || "/home/private"

      case File.read(Path.join(dir, "#{account}.gitea_token")) do
        {:ok, raw} ->
          # `no_role_token` COUVRE AUSSI LE FICHIER VIDE, comme dans le vrai service. Rendre une
          # ligne vide ferait passer « aucun jeton » pour « ce jeton-ci », et le refus arriverait
          # de la forge, en 401, loin d'ici.
          case String.trim(raw) do
            "" -> "FAIL:no_role_token"
            token -> token
          end

        {:error, _} ->
          "FAIL:no_role_token"
      end
    else
      "FAIL:bad_role"
    end
  end
end

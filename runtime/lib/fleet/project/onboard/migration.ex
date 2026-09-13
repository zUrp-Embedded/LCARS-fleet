defmodule Fleet.Project.Onboard.Migration do
  @moduledoc """
  Moves projects between catalogue orgs and reconciles local faces with forge inventory.
  Release eval doors execute these operations and report outcomes; they are not dry runs.
  Only reconcile's check mode avoids project mutations.
  """

  alias Fleet.Project.GitOps
  alias Fleet.Project.Onboard
  alias Fleet.Project.Onboard.Faces
  alias Fleet.Project.Onboard.Refute
  alias Fleet.Project.Onboard.Repo

  require Logger

  @doc """
  Transfers the forge repository to the target catalogue, then repoints local origins.

  Local paths are keyed by project name, so the org change leaves their paths unchanged.
  Only directories with a .git directory are repointed; others are reported in absent,
  including linked worktrees. Existing origins are not checked against the source.

  There is no quiescence check or rollback. A URL/repoint failure can follow a successful
  transfer and leave some origins unchanged; in-flight work and target role compatibility
  are not validated here. Forge metadata/permission transfer is delegated to the API.
  """
  @spec migrate(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def migrate(full_name, target_catalogue, opts \\ [])
      when is_binary(full_name) and is_binary(target_catalogue) do
    name = Fleet.Layout.project_name(full_name)
    dirs = Faces.face_dirs(name, opts)

    # Local target checks precede the manifest's forge read.
    with :ok <- refute_same_catalogue(full_name, target_catalogue),
         :ok <- require_target_installed(target_catalogue),
         :ok <- Refute.refute_store(full_name, opts),
         {:ok, new_full_name} <-
           Repo.repo_mod(opts).transfer_repo(full_name, target_catalogue, Repo.fc_opts(opts)),
         {:ok, url} <- Repo.repo_url(new_full_name, opts),
         {:ok, repointed} <- repoint_faces(dirs, url) do
      Logger.info(
        "ProjectOnboard: #{full_name} MIGRE vers #{new_full_name} — " <>
          "#{length(repointed)}/#{map_size(dirs)} faces repointees sur #{url}"
      )

      {:ok,
       %{
         repo: new_full_name,
         from: full_name,
         faces: Enum.reverse(repointed),
         absent: Enum.sort(Map.values(dirs) -- repointed)
       }}
    end
  end

  defp refute_same_catalogue(full_name, target) do
    case String.split(full_name, "/") do
      [^target | _] -> {:error, {:already_in_catalogue, target}}
      _ -> :ok
    end
  end

  # An uninstalled destination catalogue would be outside this container's discovery scope.
  defp require_target_installed(target), do: Onboard.require_installed(target)

  # Report completed repoints, not the target list: this container may have no local faces.
  defp repoint_faces(dirs, url) do
    Enum.reduce_while(Map.values(dirs), {:ok, []}, &repoint_one(&1, &2, url))
  end

  # Skipping a missing .git directory does not undo the already completed forge transfer.
  defp repoint_one(dir, {:ok, done}, url) do
    if File.dir?(Path.join(dir, ".git")) do
      case GitOps.run(["-C", dir, "remote", "set-url", "origin", url], auth: false) do
        :ok -> {:cont, {:ok, [dir | done]}}
        {:error, reason} -> {:halt, {:error, {:remote_repoint_failed, dir, reason}}}
      end
    else
      {:cont, {:ok, done}}
    end
  end

  @doc """
  Runs migration from a release eval, prints its result and halts.

      bin/lcars_fleet eval 'Fleet.Project.Onboard.eval_migrate("fleet/vitrine", "web")'

  Starts the forge HTTP pool without booting a second fleet. Exit codes: 0 success,
  1 named catalogue/owner refusal, 2 other error.
  """
  @spec eval_migrate(String.t(), String.t()) :: no_return()
  def eval_migrate(full_name, target) when is_binary(full_name) and is_binary(target) do
    # Release eval loads without starting the app: start only the HTTP pool, not a second fleet.
    {:ok, _sup} = Supervisor.start_link([Fleet.Forge.finch_spec()], strategy: :one_for_one)

    # Keep logger output separate from the operator report.
    Fleet.ReleaseDoor.claim_stdout!()

    case migrate(full_name, target) do
      {:ok, %{repo: new_name, faces: faces, absent: absent}} ->
        IO.puts("migre : #{full_name} -> #{new_name}")
        for d <- faces, do: IO.puts("  origin repointe : #{d}")

        for d <- absent, do: IO.puts("  face absente (jamais ouverte ici) : #{d}")

        System.halt(0)

      {:error, {:catalogue_not_installed, cat, gestures}} ->
        IO.puts(
          :stderr,
          "REFUSE : le catalogue #{inspect(cat)} n'est pas installe sur ce conteneur."
        )

        IO.puts(:stderr, "  #{gestures}")
        System.halt(1)

      {:error, {:already_in_catalogue, cat}} ->
        IO.puts(:stderr, "REFUSE : #{full_name} est deja dans le catalogue #{inspect(cat)}.")
        System.halt(1)

      # Give the observed owner-required 403 a specific diagnostic instead of a raw HTTP tuple.
      {:error, {:http, 403, %{"message" => "user should be the owner of the repo"}}} ->
        IO.puts(:stderr, "REFUSE : le compte de service n'est pas proprietaire de #{full_name}.")

        IO.puts(
          :stderr,
          "  un transfert Gitea exige le PROPRIETAIRE du depot (pas l'admin) — le compte qui"
        )

        IO.puts(:stderr, "  fait tourner la fleet est membre, pas proprietaire.")
        IO.puts(:stderr, "  il faut une identite de classe onboarding : c'est une decision de")
        IO.puts(:stderr, "  deploiement, pas un reglage de cette commande.")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "ECHEC : #{inspect(reason)}")
        System.halt(2)
    end
  end

  @doc """
  Lists forge-declared projects and checks or imports their local faces.

      bin/lcars_fleet eval 'Fleet.Project.Onboard.eval_reconcile(:check)'
      bin/lcars_fleet eval 'Fleet.Project.Onboard.eval_reconcile(:apply)'

  Provisioning parses stdout: DEJA / MANQUE in check mode, DEJA / IMPORTE in apply,
  ECHEC for returned errors, RIEN for an empty inventory. Exit codes are 1 if any failed,
  otherwise 2 if any missing, otherwise 0. Returned per-project failures do not stop
  later entries; uncaught exceptions can abort the invocation.
  """
  @spec eval_reconcile(:check | :apply) :: no_return()
  def eval_reconcile(mode) when mode in [:check, :apply] do
    # Start the HTTP pool for release eval without starting the fleet.
    {:ok, _sup} = Supervisor.start_link([Fleet.Forge.finch_spec()], strategy: :one_for_one)

    # Provisioning parses stdout; ReleaseDoor separates logs from that protocol.
    Fleet.ReleaseDoor.claim_stdout!()

    entries = reconcile(mode)

    case entries do
      [] -> IO.puts("RIEN aucun projet declare dans les catalogues installes")
      _ -> Enum.each(entries, &IO.puts(reconcile_line(&1)))
    end

    cond do
      Enum.any?(entries, &(&1.status == :failed)) -> System.halt(1)
      Enum.any?(entries, &(&1.status == :missing)) -> System.halt(2)
      true -> System.halt(0)
    end
  end

  @doc """
  Returns repo/status/reason entries for repositories in installed catalogue orgs.

  A successful read of .lcars.json on main admits a repository without validating its contents.
  Missing declarations are skipped; unreadable declarations or orgs are reported as failed.

  Check tests only that all three local directories exist, not their Git identities.
  Apply delegates to Onboard.import, which can refuse partial local state rather than repair it.
  Its default architect callback reports deferred; callers may override it.
  """
  @spec reconcile(:check | :apply, keyword()) :: [
          %{repo: String.t(), status: atom(), reason: term()}
        ]
  def reconcile(mode, opts \\ []) when mode in [:check, :apply] do
    Enum.flat_map(Onboard.installed_orgs(), &reconcile_org(&1, mode, opts))
  end

  # Preserve unreadable orgs as failures; an empty list would incorrectly mean no work.
  defp reconcile_org(org, mode, opts) do
    case Repo.repo_mod(opts).list_org_repos(org, Repo.fc_opts(opts)) do
      {:ok, names} ->
        names |> Enum.sort() |> Enum.flat_map(&reconcile_repo(&1, mode, opts))

      {:error, reason} ->
        [%{repo: "#{org}/*", status: :failed, reason: {:org_unreadable, reason}}]
    end
  end

  defp reconcile_repo(full_name, mode, opts) do
    case declared_project?(full_name, opts) do
      {:ok, true} -> [converge_project(full_name, mode, opts)]
      {:ok, false} -> []
      {:error, reason} -> [%{repo: full_name, status: :failed, reason: reason}]
    end
  end

  defp declared_project?(full_name, opts) do
    file = Fleet.Layout.project_declaration_file()
    fc = Keyword.put(Repo.fc_opts(opts), :ref, "main")

    case Repo.files_mod(opts).get_file(full_name, file, fc) do
      {:ok, _} -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      {:error, reason} -> {:error, {:declaration_unreadable, file, reason}}
    end
  end

  defp converge_project(full_name, :check, opts) do
    dirs = Faces.face_dirs(Fleet.Layout.project_name(full_name), opts)

    # Check all three directories; a partial project remains missing even if code is present.
    if Enum.all?([dirs.code, dirs.ops, dirs.workshop], &File.dir?/1),
      do: %{repo: full_name, status: :present, reason: nil},
      else: %{repo: full_name, status: :missing, reason: nil}
  end

  # Eval has no spawn supervisor. Report deferred by default rather than crash after import.
  # This callback does not schedule a future ensure; live fleet lifecycle owns that work.
  defp converge_project(full_name, :apply, opts) do
    opts =
      Keyword.put_new(opts, :ensure_architect, fn _repo, _o ->
        {:deferred, "aucune fleet dans cette VM — le poller l'assure au demarrage"}
      end)

    # Qualify the facade call: bare import is an Elixir special form.
    case Onboard.import(full_name, opts) do
      {:ok, %{idempotent: true}} -> %{repo: full_name, status: :already, reason: nil}
      {:ok, _} -> %{repo: full_name, status: :imported, reason: nil}
      {:error, reason} -> %{repo: full_name, status: :failed, reason: reason}
    end
  end

  defp reconcile_line(%{repo: repo, status: :failed, reason: reason}),
    do: "ECHEC   #{repo} — #{inspect(reason)}"

  defp reconcile_line(%{repo: repo, status: status}) do
    word =
      case status do
        :present -> "DEJA"
        :already -> "DEJA"
        :imported -> "IMPORTE"
        :missing -> "MANQUE"
      end

    "#{String.pad_trailing(word, 7)} #{repo}"
  end

  @doc """
  Reapplies canonical main protection when the forge reports an ops branch.
  This is a readiness heuristic, not proof of a complete onboarding. Absence skips the write;
  unreadable branch state is an error. No repository names are special-cased.

  The rule sizes approvals from the local card jury, disables direct pushes, dismisses stale
  approvals, blocks rejected reviews and requires CI / * status contexts.

  Passes the supplied options both to local role resolution and as nested forge_opts.
  """
  @spec reconcile_main_protection(String.t(), keyword()) :: :ok | {:error, term()}
  def reconcile_main_protection(repo, forge_opts) when is_binary(repo) do
    opts = Keyword.put(forge_opts, :forge_opts, forge_opts)

    case seeded_project?(repo, opts) do
      {:ok, true} -> Faces.protect_main(repo, opts)
      {:ok, false} -> :ok
      {:error, reason} -> {:error, {:seeded_unreadable, reason}}
    end
  end

  # Keep unknown distinct from absent so a failed probe is not recorded as successful reconciliation.
  defp seeded_project?(repo, opts) do
    Repo.repo_mod(opts).branch_exists?(repo, "ops", Repo.fc_opts(opts))
  end
end

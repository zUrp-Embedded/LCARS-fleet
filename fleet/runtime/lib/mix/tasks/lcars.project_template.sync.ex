defmodule Mix.Tasks.Lcars.ProjectTemplate.Sync do
  # Z4 — Mix task classified into the boundary of its subject (the onboarding forge surface).
  use Boundary, classify_to: Fleet.Pilot

  @shortdoc "Projects priv/project_template onto the forge template repo (fleet/project-template)"

  @moduledoc """
  Pushes `priv/project_template/**` to the forge TEMPLATE repo, marks it `template: true`
  and seeds the static protocol labels — the native-scaffolding source `ProjectOnboard`
  generates new projects from (`generate_repo`).

  The SSoT stays `priv/project_template` in THIS repo; the forge template is its
  PROJECTION (force-pushed: a diverging forge copy is overwritten, never merged).
  Operator task — run at deploy when the template files change; a missing template only
  degrades onboarding to the bare-create + local-scaffold fallback (LOUD, never a wall).

  Reads the forge coordinates from the ENV (`FORGE_BASE_URL` + `FORGE_TOKEN_FILE`, the
  same vars `bin/fleet_v2` sources) and passes them as explicit ForgeClient opts —
  DELIBERATELY no `app.start`: booting :lcars_fleet here would start a SECOND fleet
  (pollers, consumers, listener bind) next to the live one. Run on the deploy host:
  `set -a; . ~/.lcars/fleet_v2.env; set +a; mix lcars.project_template.sync`.

  **Last revised**: 2026-07-18
  """

  use Mix.Task

  @template_dir "priv/project_template"

  @impl true
  def run(_args) do
    Mix.Task.run("loadpaths")
    {:ok, _} = Application.ensure_all_started(:req)
    # The ForgeClient transport rides the app-supervised Finch pool — absent here (no
    # app.start, by design): start the SAME child spec under a task-local supervisor.
    {:ok, _} =
      Supervisor.start_link([Fleet.Pilot.Application.forge_finch_spec()], strategy: :one_for_one)

    fc = forge_opts!()
    repo = Fleet.Pilot.ProjectOnboard.project_template()
    [org, name] = String.split(repo, "/", parts: 2)

    with :ok <- ensure_repo(org, name, repo, fc),
         :ok <- push_template(repo, fc),
         :ok <- Fleet.Pilot.ForgeClient.Repo.set_template(repo, true, fc),
         :ok <- Fleet.Pilot.ForgeClient.ensure_protocol_labels(repo, fc) do
      Mix.shell().info("project-template: #{repo} synced (content + template flag + labels)")
    else
      {:error, reason} -> Mix.raise("project-template sync FAILED: #{inspect(reason)}")
    end
  end

  defp forge_opts!() do
    base = System.get_env("FORGE_BASE_URL") || Mix.raise("FORGE_BASE_URL missing (source ~/.lcars/fleet_v2.env)")

    token_file =
      System.get_env("FORGE_TOKEN_FILE") || Mix.raise("FORGE_TOKEN_FILE missing (source ~/.lcars/fleet_v2.env)")

    [base_url: base, token: token_file |> File.read!() |> String.trim()]
  end

  defp ensure_repo(org, name, repo, fc) do
    case Fleet.Pilot.ForgeClient.Repo.create_repo(
           name,
           Keyword.merge(fc,
             org: org,
             description: "Modèle de projet fleet — généré par mix lcars.project_template.sync",
             auto_init: false
           )
         ) do
      {:ok, :already_exists} -> :ok
      {:ok, ^repo} -> :ok
      {:ok, other} when is_binary(other) -> :ok
      {:error, _} = err -> err
    end
  end

  # Force-push the priv tree as a single fresh commit (the projection semantics: the forge
  # copy mirrors priv exactly; git history of the template repo is NOT load-bearing).
  defp push_template(repo, fc) do
    creds_url = authed_url(Keyword.fetch!(fc, :base_url), Keyword.fetch!(fc, :token), repo)
    push_template_to(creds_url)
  end

  # Token-in-URL for the one-shot push (the URL never leaves this process; same channel
  # the runtime's own pushes use).
  defp authed_url(base, token, repo) do
    uri = URI.parse(String.trim_trailing(base, "/"))
    %{uri | userinfo: "oauth2:#{token}"} |> URI.to_string() |> Kernel.<>("/" <> repo <> ".git")
  end

  defp push_template_to(url) do
    src = Application.app_dir(:lcars_fleet, @template_dir)
    tmp = Path.join(System.tmp_dir!(), "lcars-tpl-sync-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(tmp)
      _ = File.cp_r!(src, tmp)

      with {_, 0} <- System.cmd("git", ["init", "-q", "-b", "main"], cd: tmp),
           {_, 0} <- System.cmd("git", ["add", "-A"], cd: tmp),
           {_, 0} <-
             System.cmd(
               "git",
               [
                 "-c",
                 "user.name=lcars-system",
                 "-c",
                 "user.email=lcars-system@lcars.local",
                 "commit",
                 "-q",
                 "-m",
                 "chore(template): sync from priv/project_template"
               ],
               cd: tmp
             ),
           {_, 0} <- System.cmd("git", ["push", "-q", "--force", url, "main"], cd: tmp) do
        :ok
      else
        {out, rc} -> {:error, {:git, rc, out}}
      end
    after
      _ = File.rm_rf(tmp)
    end
  end
end

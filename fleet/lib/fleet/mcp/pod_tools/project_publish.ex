defmodule Fleet.MCP.PodTools.ProjectPublish do
  @moduledoc """
  ASYNC worker behind the `project_publish` tool (phase 2 of chantier-publication-github).

  The tool call itself only ENQUEUES (a Task under `Fleet.MCP.PublishTaskSupervisor`) and returns
  `queued` — filter-repo rewrites the WHOLE history every run (O(history), ~minutes on a large repo),
  so the pod's turn must not block on it. This module IS that Task's body.

  It resolves the project's PER-HUMAN publish binding (`~/.lcars/publish/<org__name>.json`, written by
  `lcars approve`), then runs the host-side rail `bin/publish-rail.sh` — which force-pushes a rolling
  branch and, if the forge CLI is present+authed (Tier 1), opens/updates the PR/MR; otherwise (Tier 2)
  it hands back a ready-to-open compare/new-MR URL. NO EXTERNAL TOKEN IS HANDLED here or by the rail:
  auth is the forge's official CLI (`gh`/`glab`, the wired git credential helper) or the operator's own
  wired helper — nothing token-shaped ever enters a pod, an argv, or a config we write.

  The outcome is emitted on the Bus (lossy/observability, `safe_emit` — a missing subscriber never
  crashes the Task): `project_publish.done` with the url and a `manual` flag (true = Tier 2, the url is a
  "PR/MR to open" link, not an opened request), or `project_publish.failed` with the reason. Not-linked /
  missing forge config / a non-zero rail / a raise all land as `.failed`, never a crash.
  """

  require Logger
  alias Fleet.EventRouter.Bus

  # Generous wall deadline: the rail re-clones the internal repo and filter-repo rewrites its whole
  # history on every run. Shell.run kills the whole process-group at the deadline.
  @rail_timeout_ms 15 * 60 * 1000

  @doc """
  Runs one publish of `repo` (internal `owner/name`) to its linked external forge, start to finish.

  Meant to be the body of a `Fleet.MCP.PublishTaskSupervisor` Task (the tool enqueues it). Always
  returns `:ok` and reports the outcome ONLY on the Bus (`project_publish.done` / `.failed`) — every
  failure path, including a raise, is turned into a `.failed` event, never a crash that the supervisor
  would restart into a re-publish.
  """
  @spec run(String.t(), String.t() | nil) :: :ok
  def run(repo, requester \\ nil) when is_binary(repo) do
    case do_run(repo) do
      {:ok, {url, manual}} ->
        Logger.info("ProjectPublish: #{repo} -> #{outcome_log(url, manual)}")

        safe_emit(
          :"project_publish.done",
          %{"repo" => repo, "url" => url, "manual" => manual, "requester_pod_id" => requester},
          repo
        )

      {:error, reason} ->
        {cat, detail} = Fleet.Event.reason_fields(reason)
        Logger.warning("ProjectPublish: #{repo} FAILED — #{detail}")

        safe_emit(
          :"project_publish.failed",
          %{
            "repo" => repo,
            "reason" => cat,
            "reason_detail" => detail,
            "requester_pod_id" => requester
          },
          repo
        )
    end

    :ok
  rescue
    e ->
      Logger.error("ProjectPublish: #{repo} RAISED — #{Exception.message(e)}")

      safe_emit(
        :"project_publish.failed",
        %{
          "repo" => repo,
          "reason" => "raised",
          "reason_detail" => Exception.message(e),
          "requester_pod_id" => requester
        },
        repo
      )

      :ok
  end

  @doc """
  The per-human binding filename key for an internal `owner/name` repo: **org-qualified** (`owner__name`)
  so two projects with the same name in different orgs (`fleet/demo`, `archives/demo`) do NOT collide on
  one `~/.lcars/publish/<key>.json`. `bin/lcars` (`cmd_approve`) derives the SAME key (`${repo//\\//__}`);
  the write and the read miss each other if the two ever diverge.
  """
  @spec binding_key(String.t()) :: String.t()
  def binding_key(repo) when is_binary(repo), do: String.replace(repo, "/", "__")

  @token_basename ".forge-token"

  defp do_run(repo) do
    slug = binding_key(repo)
    base = fresh_work(slug)
    work = Path.join(base, "clone")

    with {:ok, b} <- read_binding(slug),
         {:ok, forge_url} <- env("FORGE_BASE_URL"),
         {:ok, forge_tok} <- materialise_token(base),
         args = rail_args(repo, b, forge_url, forge_tok, work),
         {:ok, {out, code}} <-
           Fleet.Credentials.Shell.run(rail_path(), args, timeout_ms: @rail_timeout_ms) do
      # ⚠ LE JETON PART AVANT LE BALAYAGE, ET C'EST TOUTE LA RAISON DE CETTE LIGNE. `sweep_work`
      # CONSERVE le repertoire en sortie 6 (« pour inspection ») : le jeton y survivrait
      # indefiniment, dans le repertoire temporaire du systeme, sur le chemin d'ERREUR — celui que
      # personne ne relit.
      _ = File.rm(Path.join(base, @token_basename))
      _ = sweep_work(base, code)

      case code do
        0 -> {:ok, parse_result(out)}
        _ -> {:error, {:rail_exit, code, last_line(out)}}
      end
    else
      # ⚠ ECHEC AVANT LE RAIL : `materialise_token/1` a pu creer `base` et y ecrire un SECRET. Le
      # `with` sort ici sans passer par le balayage ci-dessus, donc c'est ICI qu'on nettoie — un
      # maillon qui ECRIT quelque chose doit nettoyer son propre chemin d'erreur.
      #
      # La clause est TOTALE (`other`), pas `{:error, _}`. Un `else` partiel leve un
      # `WithClauseError` sur toute forme non prevue : le maillon suivant deciderait ce que fait le
      # chemin d'erreur du maillon precedent, et le secret resterait sur le disque.
      other ->
        _ = File.rm_rf(base)
        other
    end
  end

  # ─── LE JETON SE DEMANDE, ET IL FINIT QUAND MEME DANS UN FICHIER ──────────────────────────────
  #
  # Lire `FORGE_TOKEN_FILE` rendrait ici le chemin d'un jeton du magasin, ouvert par le rail SOUS
  # L'UID DU POD — donc sous celui de l'humain, a travers un groupe dont l'appartenance est une
  # projection refaite periodiquement.
  #
  # ⚠ CE LECTEUR-CI N'EST PAS DE LA MEME CLASSE QUE LES DEUX AUTRES. `lcars publish run` est tape
  # par un humain qui voit le refus ; ici c'est un AGENT en vol, au milieu d'un workflow. Son echec
  # touche l'arbitrage « on ne perd pas de travail », d'ou le soin sur les deux chemins de sortie.
  #
  # Le fichier reste parce que `publish-rail.sh` prend un CHEMIN. Passer le jeton en argument le
  # mettrait dans `/proc/<pid>/cmdline`. Ce fichier-ci vit dans un repertoire `0700` que ce process
  # vient de creer, porte `0600`, et meurt avec le geste.
  #
  # ⚠ `:exclusive` A L'ECRITURE : le fichier doit etre NEUF. Sans ce mode, un fichier pose la par un
  # tiers — meme chemin, deja ouvert par lui — se verrait ecraser d'un jeton frais qu'il tiendrait
  # encore. `base` est unique par run, donc le cas est theorique ; ecrire un secret sur un
  # descripteur qu'on n'a pas cree ne se fait pas sur la foi d'un « ca n'arrivera pas ».
  defp materialise_token(base) do
    with {:ok, account} <- forge_account(),
         {:ok, token} <- ask_authority(account),
         :ok <- File.mkdir_p(base),
         :ok <- File.chmod(base, 0o700),
         path = Path.join(base, @token_basename),
         :ok <- File.write(path, token, [:exclusive]),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    else
      {:error, {_, _} = named} -> {:error, named}
      {:error, reason} -> {:error, {:forge_token_unavailable, reason}}
    end
  end

  defp forge_account do
    case Fleet.Credentials.ForgeAuth.account() do
      nil -> {:error, {:env_missing, "FORGE_PUSH_ACCOUNT"}}
      account -> {:ok, account}
    end
  end

  defp ask_authority(account) do
    case Fleet.Credentials.ForgeAuth.token_for(account) do
      {:ok, token} -> {:ok, token}
      {:error, cause} -> {:error, {:forge_token_unavailable, cause}}
    end
  end

  # NOBODY ELSE SWEEPS, AND THE RAIL CANNOT: it is the caller who allocates `--work`, and the rail
  # refuses a path that already exists (phase 1, `lcars approve`, sweeps its own with
  # `trap 'rm -rf' EXIT`). Without this, every publish leaves a COMPLETE rewritten clone of the
  # project in the system temp dir, forever: the size of the repository, once per publication. A
  # unique path per run satisfies the rail's refusal and answers nothing about the previous one.
  #
  # A COMPOUND EFFECT WORTH NAMING: `System.unique_integer/1` is unique WITHIN a runtime instance and
  # restarts low after a reboot. With nothing ever swept, a path left by a pre-restart run can be
  # drawn again — and the rail then refuses with "--work must be a fresh path", failing the publish
  # for a reason with no relation to publishing.
  #
  # EXIT 6 IS THE EXCEPTION, and it is deliberate on the rail's side: it means the rewrite lost its
  # determinism, and it leaves the clone "pour inspection". Sweeping it would erase the only evidence
  # of the one failure nobody can diagnose after the fact.
  @keep_work_on_exit 6

  @doc false
  @spec sweep_work(String.t(), integer()) ::
          :kept_for_inspection | {:ok, [binary()]} | {:error, term(), binary()}
  def sweep_work(_work, @keep_work_on_exit), do: :kept_for_inspection
  def sweep_work(work, _code), do: File.rm_rf(work)

  # The per-human binding is the source of truth for WHERE this project publishes (chantier §5bis).
  #
  # ⚠ `base` EST UNE CLE REQUISE, et elle ne l'etait pas. `rail_args/5` faisait
  # `Map.get(b, "base") || "main"` : une liaison ecrite par une version anterieure d'`approve`,
  # editee a la main ou tronquee publiait donc silencieusement contre `main`, quelle que soit la
  # branche par defaut de la destination. Le defaut avait DEUX entrees independantes — l'ecriture
  # (`approve` supposait `main`) et la lecture (ici). Fermer une seule des deux laissait le rail
  # casse par l'autre. Une liaison qui ne dit pas ou elle publie n'est pas une liaison : elle est
  # refusee par son nom (`{:binding_missing_keys, …}`), jamais completee par une supposition.
  defp read_binding(slug) do
    path = Path.join([System.user_home!(), ".lcars", "publish", "#{slug}.json"])

    with {:ok, raw} <- file_read(path, {:not_linked, slug}),
         {:ok, map} when is_map(map) <- decode(raw, {:binding_invalid, path}),
         :ok <- require_keys(map, ~w(host dest_host dest_repo base), path) do
      {:ok, map}
    end
  end

  defp file_read(path, err) do
    case File.read(path) do
      {:ok, r} -> {:ok, r}
      {:error, _} -> {:error, err}
    end
  end

  defp decode(raw, err) do
    case Jason.decode(raw) do
      {:ok, m} -> {:ok, m}
      {:error, _} -> {:error, err}
    end
  end

  defp require_keys(map, keys, path) do
    missing = Enum.reject(keys, fn k -> is_binary(Map.get(map, k)) and Map.get(map, k) != "" end)
    if missing == [], do: :ok, else: {:error, {:binding_incomplete, path, missing}}
  end

  defp env(var) do
    case System.get_env(var) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:env_missing, var}}
    end
  end

  defp rail_args(repo, b, forge_url, forge_tok, work) do
    [
      "--project",
      repo,
      "--forge",
      forge_url,
      "--forge-token-file",
      forge_tok,
      "--host",
      b["host"],
      "--dest-repo",
      b["dest_repo"],
      "--dest-host",
      b["dest_host"],
      "--base",
      b["base"],
      "--work",
      work
    ]
  end

  # publish-rail.sh is co-located with the launchers (moved to bin/, install manifest). The bin dir is
  # the one already resolved for the launcher; reading its config keeps a single source of the bin
  # location without an MCP->Spawner call (config read, not a boundary edge). Namespace is the post-D-07
  # `:lcars_fleet` app with a domain-prefixed key; the pre-migration spawner atom is dead.
  defp rail_path do
    launcher =
      Application.get_env(
        :lcars_fleet,
        :spawner_claude_launch_path,
        "/usr/local/bin/claude_launch.sh"
      )

    Path.join(Path.dirname(launcher), "publish-rail.sh")
  end

  # Le repertoire PORTEUR d'un run, unique. Le clone est `<base>/clone` et le jeton `<base>/.forge-token`.
  #
  # ⚠ CE N'EST PLUS `--work` LUI-MEME, ET LA DISTINCTION COMPTE : le rail REFUSE un `--work` qui
  # existe deja. Rendre ce chemin directement au rail ET y ecrire le jeton avant de l'appeler
  # ferait echouer chaque publication sur « --work doit etre un chemin neuf ». D'ou le niveau
  # intermediaire : le repertoire est a nous, le chemin que le rail recoit reste vierge.
  defp fresh_work(slug) do
    Path.join(System.tmp_dir!(), "lcars-publish-#{slug}-#{System.unique_integer([:positive])}")
  end

  # The rail prints the url after `-> ` on success. Two shapes:
  #   Tier 1 auto: "PR/MR ouverte -> <pull/MR url>" / "actualisee ... -> <pull/MR url>"
  #   Tier 2 degraded: "branche ... poussee -- ouvre la PR/MR ici -> <compare|merge_requests/new url>"
  # "rien a publier" is a legitimate no-op success with no url. `manual` is inferred from the URL SHAPE
  # (compare / new-MR forms), not from prose: the rail's Tier-2 outcome is a "one more click", relayed
  # to the pod as such rather than as an opened request.
  defp parse_result(out) do
    url = parse_url(out)
    {url, manual_url?(url)}
  end

  defp parse_url(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value("", fn line ->
      case Regex.run(~r{->\s*(https?://\S+)}, line) do
        [_, url] -> url
        _ -> false
      end
    end)
  end

  defp manual_url?(url), do: url =~ ~r{/compare/} or url =~ ~r{/merge_requests/new}

  defp outcome_log(url, _manual) when url == "", do: "nothing to publish"
  defp outcome_log(url, true), do: "pushed, PR/MR to open -> #{url}"
  defp outcome_log(url, false), do: url

  defp last_line(out) do
    out |> String.split("\n", trim: true) |> List.last() |> Kernel.||("")
  end

  # ⚠ REND `:ok` EXPLICITEMENT, ET C'EST CE QUI REND LE `@spec` DE `run/2` VRAI. `Bus.safe_emit/4`
  # rend `:ok | {:error, _}` ; les branches de `run/2` se terminaient dessus, donc la fonction
  # rendait ce type-la alors que son spec annonce `:: :ok`. Un spec qui ment est pire qu'un spec
  # absent : dialyzer l'a dit en `unmatched_return`, et le lecteur, lui, l'aurait cru.
  #
  # Le rejet est DELIBERE : le Bus est le rail lossy (doctrine D1), `run/2` rapporte son issue par
  # evenement et ne doit JAMAIS crasher — un raise ici ferait redemarrer la Task, donc re-publier.
  # `safe_emit` loggue deja ses propres echecs.
  @spec safe_emit(atom(), map(), String.t()) :: :ok
  defp safe_emit(type, payload, repo) do
    _ = Bus.safe_emit(:mcp, type, [payload: payload], context: "ProjectPublish: #{repo}")
    :ok
  end
end

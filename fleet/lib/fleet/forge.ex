defmodule Fleet.Forge do
  @moduledoc """
  Forge domain facade — the SINGLE HTTP exit of the fleet toward its git forge.

  Boundary anchor; the contract lives in each module's `@moduledoc`: `Fleet.Forge.Client` (the
  surface: issues, labels, comments, pulls, reviews, merges), `Fleet.Forge.Client.Transport` (the
  only module that speaks HTTP), `Fleet.Forge.Client.Repo`, `.Files`, `.Jury`, `.UrlSafe`, and
  `Fleet.Forge.Protocol` (the wire vocabulary: branch naming, PR titles, parsing).

  ## Why it is a domain and not a corner of `Fleet.Pilot`

  It was a corner of Pilot, and the cost showed in the boundary declaration: `Req` and
  `Req.Response` were deps of the BUSINESS domain, so "one HTTP exit" was a convention anyone could
  break by adding a call anywhere in the pilot. Here the same rule is COMPILED — the HTTP library
  is declared by this boundary and nothing else can reference it.

  It never belonged to Pilot in the first place: outside its own modules it touched the pilot three
  times, while what it actually depends on is `Fleet.Labels`, `Fleet.Workflow` and
  `Fleet.Credentials`. It was placed there, not derived from there.

  ## The Finch pool name has one authority

  `finch_name/0`, and it is a FUNCTION rather than a literal because two places need the same atom
  from opposite sides: `Fleet.Pilot.Application` starts the pool, `Fleet.Forge.Client.Transport`
  sends through it. Two literals in two domains is exactly the pairing that drifts silently — the
  pool starts under one name and the requests go to another, which fails at the first call and
  reads like a network problem.
  """

  # COMPILED domain boundary: deps = the declared inter-domain graph, exports = the MEASURED
  # cross-domain surface. `Req`/`Req.Response` are fenced HERE and nowhere else: that fencing IS
  # the "single HTTP exit" invariant, and it is the reason this domain exists.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.GitRef,
      Fleet.Labels,
      Fleet.Layout,
      # C2 — the gate reads the judges' machine verdict out of the review bodies it already
      # fetches; the wire format is a foundation primitive shared with the writer side (Pilot).
      Fleet.FindingsWire,
      Fleet.EnvParse,
      Fleet.Opts,
      Fleet.Credentials,
      Fleet.Workflow,
      Fleet.Event,
      Fleet.EventRouter,
      # — external wire surface (lib fencing: every reference is declared) —
      Req,
      Req.Response,
      # The pool this domain sends through: its NAME lived here and its SHAPE in Pilot.Application,
      # which split one fact across two domains and put the pool out of reach of a tool door that
      # legitimately needs it. Name and shape now sit together, and this declaration is the cost.
      Finch
    ],
    exports: [
      Client,
      Client.Jury,
      Client.Repo,
      Client.Files,
      Client.UrlSafe,
      Protocol,
      # LA LECTURE DES CHARGES, EXPORTEE A DESSEIN — et `boundary` a exige que ce soit dit.
      #
      # Ce domaine rend les reponses de la forge telles quelles : des maps JSON. Quatorze modules
      # de `pilot`, `mcp`, `admiral` et `application` les indexaient par clef string, donc la forme
      # de l'API d'un tiers etait connue hors d'ici — une montee de version se traitait au `grep`.
      # `Payload` est la couche qui ferme ca : UN chemin par fait, declare une fois, verifie contre
      # une capture REELLE (`test/fixtures/forge/`).
      #
      # L'exporter est le geste inverse d'une fuite : au lieu que chacun connaisse la forme, un
      # seul module la connait et les autres lui posent des questions. Le mur qui suit interdira
      # les clefs string discriminantes hors de ce domaine — sans cet export, il n'aurait pas
      # d'alternative a offrir.
      Payload,
      # Called by the pilot wherever IT writes to the forge — the spacing is a property of the
      # write, so it belongs to the domain that owns the writes.
      WriteSpacing
    ]

  @finch_name Fleet.Forge.Finch

  @doc """
  Name of the forge HTTP connection pool (a Finch pool NAME, not a module).

  Read by the supervisor that starts the pool and by the transport that sends through it. Neither
  side may hardcode it: see the moduledoc.
  """
  @spec finch_name() :: atom()
  def finch_name, do: @finch_name

  @doc """
  Child spec of that pool — SINGLE writer of its shape.

  `conn_max_idle_time: 30_000` closes any connection left idle >30s BEFORE the forge closes it
  server-side (Finch's `:infinity` default would keep it until it goes stale, and the next call then
  hangs until `receive_timeout` — the suspected source of the ~30s cumulated on create_issue).

  It lives beside the NAME because the two are one fact. While the shape lived in the pilot's
  application module, anything that was not the pilot could name the pool but not START it: an
  `eval` door acting on the forge died on `unknown registry: Fleet.Forge.Finch`, and its only ways
  out were to depend on the pilot or to write the shape a second time. Out-of-app callers start it
  standalone under their own supervisor (the `eval` doors: `Onboard.eval_migrate/2`,
  `Onboard.eval_reconcile/1`, `CatalogueLifecycle`) — never `app.start`, because a second fleet must
  not boot from a tool.
  """
  @spec finch_spec() :: {module(), keyword()}
  def finch_spec, do: {Finch, name: @finch_name, pools: %{default: [conn_max_idle_time: 30_000]}}

  @doc """
  The repo's forge id, EXPLAINED: `{:ok, id}` | `{:error, reason}`.

  TWO SHAPES, one authority, because the callers are not asking the same question. The pilot's
  `Spawn.resolve_repo_id/3` wraps this one to `nil` and puts the id through `Opts.maybe_put` — for those, `nil` is the right answer to "optional, absent",
  and an `{:error, _}` they must unwrap would be noise. `Fleet.Project.Architect` makes it a FAILURE
  condition (no id ⇒ no project identity ⇒ no arch), and a failure has to say why: it used to get a
  bare `nil` and then GUESS in its log ("forge down?") over a forge that was answering. An
  instrument that supposes is worse than one that is silent — the supposition gets quoted.

  It lives HERE and not in the dispatcher that used to hold it: reading a repo's forge id is a
  FORGE question, and the dispatcher was simply its first caller. The extraction of the project
  lifecycle is what surfaced it — an architect needs the id to exist, and had to reach up into the
  step rail to ask for it.

  Reasons: the forge's own (`{:error, :no_id}`, HTTP tuple…), or `:repo_id_unsupported` when the
  seam module does not export `repo_id/2` at all (a test stub) — which is a fact about the wiring,
  not about the forge, and must never be reported as the latter.
  """
  @spec repo_id(module(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def repo_id(forge, repo, forge_opts) do
    # `Code.ensure_loaded?/1` FIRST, and it is load-bearing: `function_exported?/3` does NOT load a
    # module — it answers about the code table as it stands. On a freshly booted BEAM the forge
    # client is not loaded yet, so the guard alone reports "this module has no repo_id/2" about a
    # module that plainly does, and every caller reads that as an absent id.
    # Measured: on a cold node, `:erlang.module_loaded(Fleet.Forge.Client)` is false and
    # `function_exported?(_, :repo_id, 2)` is false; after `Code.ensure_loaded?/1`, both are true.
    # The visible symptom was the FIRST project onboarded after a start losing its architect, with
    # a log blaming the forge — which was answering the whole time.
    if Code.ensure_loaded?(forge) and function_exported?(forge, :repo_id, 2) do
      case forge.repo_id(repo, forge_opts) do
        {:ok, id} when is_integer(id) and id >= 0 -> {:ok, id}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_repo_id, other}}
      end
    else
      {:error, :repo_id_unsupported}
    end
  end

  @doc """
  Renders a forge error for a HUMAN — the form an operator-facing payload uses.

  `inspect/1` on the raw reason is right in a LOG (a grep rail, where the whole payload is the
  point) and wrong in a forge comment. Gitea puts a `"url" => ".../api/swagger"` pointer in every
  error body, and pasting the tuple verbatim shipped that pointer into the message a human reads.
  Measured 2026-08-11 on a stalled PR: the signal was `403 user must be a collaborator`, and the
  swagger URL — meaningless to any reader of that comment — was taken for signal twice, once by a
  human asking which forge it named and once inside an architect's root-cause analysis.

  Noise that survives into a message read by a decision-maker is not neutral: it gets interpreted.
  Operation tags are KEPT (`{:open_pr, _}` says which gesture failed) — only the vendor's
  boilerplate is dropped.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error({:http, status, %{"message" => message}}) when is_binary(message),
    do: "HTTP #{status} — #{message}"

  def describe_error({tag, inner}) when is_atom(tag),
    do: "#{tag} : #{describe_error(inner)}"

  def describe_error(other), do: inspect(other)
end

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
      Fleet.EnvParse,
      Fleet.Opts,
      Fleet.Credentials,
      Fleet.Workflow,
      Fleet.Event,
      Fleet.EventRouter,
      # — external wire surface (lib fencing: every reference is declared) —
      Req,
      Req.Response
    ],
    exports: [
      Client,
      Client.Jury,
      Client.Repo,
      Client.Files,
      Client.UrlSafe,
      Protocol,
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
end

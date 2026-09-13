defmodule Fleet.Forge do
  @moduledoc """
  Forge HTTP domain and Boundary anchor; module map: lib/fleet/forge/README.md.
  Req/Finch references are declared here under the project's compile-time boundary checks.
  Those checks constrain declared dependencies, not arbitrary runtime network access.

  finch_name/0 and finch_spec/0 share the pool identity and configuration used by Pilot's
  supervisor, Forge transport and standalone tool callers. A name mismatch otherwise appears
  at the first request as a missing pool, easily confused with a transport failure.
  """

  use Boundary,
    deps: [
      Fleet.Opts,
      Fleet.Slug,
      Fleet.GitRef,
      Fleet.Labels,
      Fleet.Layout,
      # Decode review verdicts with the same wire format used by Pilot's writers.
      Fleet.FindingsWire,
      Fleet.EnvParse,
      Fleet.Opts,
      Fleet.Credentials,
      Fleet.Workflow,
      Fleet.Event,
      Fleet.EventRouter,
      Req,
      Req.Response,
      Finch
    ],
    exports: [
      Client,
      Client.Jury,
      Client.Repo,
      Client.Files,
      Client.UrlSafe,
      Protocol,
      # External consumers read raw response maps through Payload, centralizing vendor keys.
      # Captured responses in test/fixtures/forge/ anchor those accessors and contract checks.
      Payload,
      # Shared spacing policy for callers writing to the forge.
      WriteSpacing
    ]

  @finch_name Fleet.Forge.Finch

  @doc """
  Finch pool registration name, not a module. Shared by its supervisor and request transport.
  """
  @spec finch_name() :: atom()
  def finch_name, do: @finch_name

  @doc """
  Shared Finch child spec. The 30-second idle setting discards stale HTTP/1 connections
  during checkout, not on a background deadline; it cannot guarantee closing before the server.
  This limits reuse after idle periods, without proving the cause of past request stalls.

  Out-of-app eval callers start this under their own supervisor, without app.start:
  starting another fleet merely to obtain HTTP transport would also start its workers.
  """
  @spec finch_spec() :: {module(), keyword()}
  def finch_spec, do: {Finch, name: @finch_name, pools: %{default: [conn_max_idle_time: 30_000]}}

  @doc """
  Calls the forge module's repo_id/2, accepting {:ok, nonnegative_integer}, preserving
  {:error, reason}, and wrapping other returns as {:unexpected_repo_id, return}.
  Missing capability returns :repo_id_unsupported, a wiring fact rather than a forge outage.
  Exceptions/exits from the module propagate. Architect needs these failure reasons;
  Spawn.resolve_repo_id/3 deliberately maps failures to nil for its optional field.
  """
  @spec repo_id(module(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def repo_id(forge, repo, forge_opts) do
    # Load before checking exports so a cold module is not mistaken for an unsupported client.
    if Fleet.Opts.exported?(forge, :repo_id, 2) do
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
  Renders an operator-facing error. For HTTP bodies with a binary message, keeps status
  and message while dropping other fields (including vendor Swagger links). Atom-tagged
  pairs keep operation context recursively; other terms fall back to inspect/1.
  Message contents and fallback terms are not redacted or escaped for their destination.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error({:http, status, %{"message" => message}}) when is_binary(message),
    do: "HTTP #{status} — #{message}"

  def describe_error({tag, inner}) when is_atom(tag),
    do: "#{tag} : #{describe_error(inner)}"

  def describe_error(other), do: inspect(other)
end

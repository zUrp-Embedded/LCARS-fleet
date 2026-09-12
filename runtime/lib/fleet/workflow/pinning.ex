defmodule Fleet.Workflow.Pinning do
  @moduledoc """
  Renders long bodies as the first eight lines plus a citation to the full text
  committed in ops. More than ten newline-separated segments triggers pinning;
  a trailing newline counts as an extra segment.

  Missing destination or a returned commit error keeps the full body inline.
  Any successful commit result produces a pointer regardless of push state, so
  the link may not be remotely readable. This renderer neither posts to the forge
  nor guarantees eventual publication. A truncation is labeled as such; it is not
  a semantic summary and can cut Markdown structures or qualifications.
  """

  require Logger

  alias Fleet.Workflow.OpsObjectSync

  # Keep short bodies inline: the pointer itself adds reading overhead.
  @threshold_lines 10

  # Preview line limit, independent of the threshold; no byte-length limit.
  @summary_lines 8

  @doc """
  Returns body unchanged or a truncated preview with a version pointer.
  Pinning needs non-nil :work_dir and :ref; these values are not otherwise validated.
  :kind defaults to Doc, :label to emission. A binary :repo delegates the link to
  Fleet.Layout; otherwise the pointer uses <kind>: <ref> @ <sha>.

  :commit_fun can replace OpsObjectSync.commit_object/4 and receives label: and
  push: :ops. Returned {:error, reason} falls back inline; exceptions, unexpected
  callback results and invalid option types are not rescued.
  """
  @spec render(String.t(), keyword()) :: String.t()
  def render(body, opts \\ []) when is_binary(body) do
    work_dir = Keyword.get(opts, :work_dir)
    ref = Keyword.get(opts, :ref)

    cond do
      not pinnable?(body) -> body
      is_nil(work_dir) or is_nil(ref) -> body
      true -> pin(body, work_dir, ref, opts)
    end
  end

  @doc "Is this body long enough to be worth pinning? Public so a caller can skip the work entirely."
  @spec pinnable?(String.t()) :: boolean()
  def pinnable?(body) when is_binary(body), do: line_count(body) > @threshold_lines

  defp pin(body, work_dir, ref, opts) do
    label = Keyword.get(opts, :label, "emission")
    repo = Keyword.get(opts, :repo)
    commit = Keyword.get(opts, :commit_fun, &OpsObjectSync.commit_object/4)

    case commit.(work_dir, ref, body, label: label, push: :ops) do
      # Keep the citation for every successful local result, even unobserved/failed push.
      {:ok, sha, _push_state} ->
        pointer_body(body, ref, sha, Keyword.get(opts, :kind, "Doc"), repo)

      {:error, reason} ->
        # Preserve the complete body when the engine returns an error.
        Logger.warning(
          "Emission: #{ref} NOT committed (#{inspect(reason)}) — full body posted inline instead " <>
            "of a pointer that would name nothing"
        )

        body
    end
  end

  defp pointer_body(body, ref, sha, kind, repo) do
    """
    #{summary(body)}

    #{disclaimer(kind)}

    #{pointer_line(kind, ref, sha, repo)}
    """
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  # Missing/non-binary repo retains the legacy pointer notation.
  defp pointer_line(kind, ref, sha, repo) when is_binary(repo),
    do: Fleet.Layout.pointer_line(kind, ref, sha, repo)

  defp pointer_line(kind, ref, sha, _repo), do: "#{kind}: #{ref} @ #{sha}"

  # Name the artifact kind so the disclaimer applies to briefs and verdicts alike.
  defp disclaimer(kind) do
    "Ce qui précède est un résumé, pas le #{String.downcase(kind)}. Ce qui fait foi est le doc " <>
      "ci-dessous, à ce commit exact — éditer ce résumé ne le change pas."
  end

  defp summary(body) do
    lines = String.split(body, "\n")
    kept = Enum.take(lines, @summary_lines)
    dropped = length(lines) - length(kept)

    Enum.join(kept, "\n") <> "\n\n_(#{dropped} lignes de plus dans le doc cité)_"
  end

  defp line_count(body), do: body |> String.split("\n") |> length()
end

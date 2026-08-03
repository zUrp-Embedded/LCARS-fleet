defmodule Mix.Tasks.Lcars.Revised do
  # Classified like its siblings: a Mix task is not a domain, it borrows the boundary of what it
  # touches. This one touches the SOURCE TREE and git, not a domain — `Fleet.Application` is the
  # same choice `lcars.catalogue.verify` made for the same reason.
  use Boundary, classify_to: Fleet.Application
  use Mix.Task

  @shortdoc "Reports the moduledoc `Last revised` dates that git contradicts"

  @moduledoc """
  245 files carry a hand-written `**Last revised**: YYYY-MM-DD` in their moduledoc, and git already
  knows the truth (`git log -1 --format=%as -- <file>`). Two sources for one fact, one of them
  maintained by hand across every commit — the drift is not a risk, it is a certainty (BL-6-44).

  This task reports the files whose header is OLDER than their last commit: someone changed the
  file and did not touch the date, so the header now states a day on which that content did not
  exist. It reads like provenance and is not.

      mix lcars.revised            # the drifted files, oldest gap first
      mix lcars.revised --summary  # counts only

  ## What it does NOT catch, measured on its first run

  It compares DAYS. A file edited today whose header already said today reads as correct whether or
  not anyone thought about the date — so on a busy day the report under-counts by construction.
  First run: **0 drifted across 245 files**, and that number means "nothing has drifted ACROSS
  DAYS", not "every header was considered". Proven able to detect: with one header pushed back to
  June, the file is named.

  Same-day blindness is not fixable with a date field — the field's granularity IS the limit, which
  is one more argument for deriving the value instead of storing it.

  ## Why a REPORT and not a gate step — the honest reason

  A gate runs on a DIRTY tree: the file being edited has no commit yet, so `git log -1` returns the
  PREVIOUS commit and every correctly-bumped file would look like it drifted forward. Skipping
  dirty files instead means the check only ever sees clean ones, so it flags a forgotten bump ONE
  COMMIT LATE — after the wrong date is already in the history it was supposed to protect.

  Neither shape earns a red. A gate that is noise on the common path gets read as noise, and a gate
  that fires late has not prevented anything. So this is a report, run when someone wants the list —
  and the real fix, the day it is worth it, is to stop maintaining the field by hand and derive it
  at doc-build time from git, which is where the fact already lives.

  **Last revised**: 2026-08-03
  """

  @header ~r/^\s*\*\*Last revised\*\*:\s*(\d{4}-\d{2}-\d{2})/m

  @impl Mix.Task
  def run(args) do
    root = File.cwd!()

    drifted =
      ["lib", "test", "etc"]
      |> Enum.flat_map(&Path.wildcard(Path.join([root, &1, "**", "*.{ex,exs,sh,md}"])))
      |> Enum.flat_map(&drift(&1, root))
      |> Enum.sort_by(fn {_f, header, commit} -> Date.diff(commit, header) end, :desc)

    if "--summary" in args do
      Mix.shell().info(
        "revised: #{length(drifted)} fichier(s) dont l'en-tete precede son dernier commit"
      )
    else
      Enum.each(drifted, fn {file, header, commit} ->
        Mix.shell().info(
          "#{Path.relative_to(file, root)}\n" <>
            "    en-tete #{header} · dernier commit #{commit} · #{Date.diff(commit, header)} jour(s) de retard"
        )
      end)

      Mix.shell().info("\n#{length(drifted)} fichier(s) en derive.")
    end
  end

  defp drift(file, root) do
    with {:ok, content} <- File.read(file),
         [_, header_str] <- Regex.run(@header, content),
         {:ok, header} <- Date.from_iso8601(header_str),
         {:ok, commit} <- last_commit_date(file, root),
         # STRICTLY older only. A header AHEAD of the last commit is the normal state of a file
         # edited-and-bumped but not yet committed, and of a deliberate forward-dating; flagging it
         # would make the common case noise.
         :lt <- Date.compare(header, commit) do
      [{file, header, commit}]
    else
      _ -> []
    end
  end

  defp last_commit_date(file, root) do
    # `--` before the path: a filename that happens to match a ref would otherwise be read as one.
    case System.cmd("git", ["log", "-1", "--format=%as", "--", file],
           cd: root,
           stderr_to_stdout: true
         ) do
      {out, 0} -> out |> String.trim() |> Date.from_iso8601()
      _ -> :error
    end
  end
end

defmodule Fleet.Workflow.PayloadGuard do
  @moduledoc """
  Validates payload paths and writes replacement files into a workspace.
  All entries are checked before the write pass: lexical containment, .git path
  components, filter=/diff= assignments in payload .gitattributes, and existing
  symlinks in the relative path chain. This checks submitted files, not every
  existing workspace file or Git configuration.

  Symlinks are checked again before each write. A same-directory temporary file
  is renamed over the destination, replacing a final symlink instead of following
  its target. Parent directories can still change after the check, and temporary
  files are not opened exclusively. The workspace root itself is trusted; these
  operations do not provide race-free confinement against a concurrent writer.

  Initial validation refusal writes nothing. A write-pass refusal or error leaves
  earlier writes in place, without rollback. Deliverable stops that call before
  commit, but residual files remain available to later operations.
  """

  @doc """
  Applies a nonempty list of maps with binary path/content and nonempty path.
  Returns :ok, :no_files_in_payload, :invalid_payload_file, a path refusal, or
  :file_write_failed inside {:error, ...}. A late :symlink_escape can follow writes
  of earlier entries. Extra map keys are ignored.

  Optional :after_validate is a zero-arity test hook between validation and writing;
  it runs in the caller and its exceptions are not rescued.
  """
  @spec apply_files(Path.t(), term(), keyword()) :: :ok | {:error, term()}
  def apply_files(workspace, files, opts \\ [])

  def apply_files(workspace, files, opts) when is_list(files) and files != [] do
    with :ok <- validate_files(workspace, files) do
      # Insert a deterministic race between passes; absent in normal calls.
      case Keyword.get(opts, :after_validate) do
        f when is_function(f, 0) -> f.()
        _ -> :ok
      end

      write_validated_files(workspace, files)
    end
  end

  def apply_files(_workspace, _other, _opts), do: {:error, :no_files_in_payload}

  defp validate_files(workspace, files) do
    Enum.reduce_while(files, :ok, fn
      # Empty path would otherwise become an opaque directory write error.
      %{"path" => rel_path, "content" => content}, :ok
      when is_binary(rel_path) and rel_path != "" and is_binary(content) ->
        case file_refusal(workspace, rel_path, content) do
          nil -> {:cont, :ok}
          cause -> {:halt, {:error, cause}}
        end

      bad, :ok ->
        {:halt, {:error, {:invalid_payload_file, inspect(bad)}}}
    end)
  end

  # Cheap lexical checks precede filesystem symlink inspection; nil means no refusal.
  defp file_refusal(workspace, rel_path, content) do
    expanded_ws = Path.expand(workspace)
    full = Path.expand(Path.join(workspace, rel_path))

    cond do
      not (full == expanded_ws or String.starts_with?(full, expanded_ws <> "/")) ->
        {:path_traversal, rel_path}

      dotgit_component?(rel_path) ->
        {:dotgit_path, rel_path}

      gitattributes_basename?(rel_path) and arms_filter_or_diff?(content) ->
        {:dangerous_gitattributes, rel_path}

      symlink_in_chain?(workspace, rel_path) ->
        {:symlink_escape, rel_path}

      true ->
        nil
    end
  end

  # Match `.git` as a path component, not `.gitignore` or `foo.git`.
  defp dotgit_component?(rel_path) do
    rel_path |> Path.split() |> Enum.any?(&(&1 == ".git"))
  end

  # `.gitattributes` can arm Git filter or diff drivers at any depth.
  defp gitattributes_basename?(rel_path) do
    Path.basename(rel_path) == ".gitattributes"
  end

  # Broad refusal of executable filter/diff attributes; other attributes remain allowed.
  defp arms_filter_or_diff?(content) do
    Regex.match?(~r/(^|\s)(filter|diff)=\S/m, content)
  end

  # `lstat` finds existing links without following them.
  defp symlink_in_chain?(workspace, rel_path) do
    rel_path
    |> Path.split()
    |> Enum.scan(workspace, fn part, acc -> Path.join(acc, part) end)
    |> Enum.any?(&symlink?/1)
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end

  # Keep the global pass so an initially invalid payload writes nothing. Per-file
  # checks narrow the later race window but do not eliminate parent-directory races.
  defp write_validated_files(workspace, files) do
    Enum.reduce_while(files, :ok, &write_one_validated(&1, &2, workspace))
  end

  # Recheck before each write; a late refusal stops the remaining files.
  defp write_one_validated(%{"path" => rel_path, "content" => content}, :ok, workspace) do
    if symlink_in_chain?(workspace, rel_path) do
      {:halt, {:error, {:symlink_escape, rel_path}}}
    else
      case write_replacing(Path.join(workspace, rel_path), content) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:file_write_failed, rel_path, reason}}}
      end
    end
  end

  # Same-directory temporary avoids cross-filesystem rename failure. Rename replaces
  # the final directory entry; parent components can still be redirected concurrently.
  defp write_replacing(full_path, content) do
    dir = Path.dirname(full_path)
    tmp = Path.join(dir, ".lcars-payload-#{:erlang.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, full_path) do
      :ok
    else
      {:error, _} = err ->
        _ = File.rm(tmp)
        err
    end
  end
end

defmodule SymphonyElixir.Recordings do
  @moduledoc """
  Locates the virtual-desktop screen recordings captured inside per-issue agent
  containers.

  When `container.record` is enabled, each container's desktop entrypoint writes
  segmented video files into the issue's bind-mounted workspace (under
  `container.recordings_dir`). Because the workspace lives on the orchestrator
  host, those recordings outlive the container and can be listed and streamed
  back through the dashboard for demo and review.
  """

  alias SymphonyElixir.{Config, PathSafety, Workspace}

  @recording_extensions ~w(.mp4 .webm .mkv)

  @type recording :: %{
          name: String.t(),
          path: Path.t(),
          size: non_neg_integer(),
          modified_at: DateTime.t() | nil
        }

  @doc """
  Whether desktop recording is currently configured (container mode enabled and
  `container.record` set).
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Config.settings() do
      {:ok, settings} -> settings.container.enabled and settings.container.record
      {:error, _reason} -> false
    end
  end

  @doc """
  Resolves the host directory where an issue's recordings are stored.

  Returns `{:error, :recordings_dir_not_on_host}` when `recordings_dir` is an
  absolute path, since that lives only inside the container.
  """
  @spec directory(String.t()) :: {:ok, Path.t()} | {:error, term()}
  def directory(issue_identifier) when is_binary(issue_identifier) do
    with {:ok, settings} <- Config.settings(),
         {:ok, workspace} <- Workspace.issue_workspace_path(issue_identifier) do
      resolve_directory(workspace, settings.container.recordings_dir)
    end
  end

  defp resolve_directory(_workspace, "/" <> _absolute), do: {:error, :recordings_dir_not_on_host}
  defp resolve_directory(workspace, recordings_dir), do: {:ok, Path.join(workspace, recordings_dir)}

  @doc """
  Lists the recordings available for an issue, newest first. Returns an empty
  list when the directory does not exist yet.
  """
  @spec list(String.t()) :: {:ok, [recording()]} | {:error, term()}
  def list(issue_identifier) when is_binary(issue_identifier) do
    with {:ok, dir} <- directory(issue_identifier) do
      {:ok, list_directory(dir)}
    end
  end

  defp list_directory(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&recording_file?/1)
        |> Enum.map(&describe(dir, &1))
        |> Enum.sort_by(& &1.name, :desc)

      {:error, _reason} ->
        []
    end
  end

  defp describe(dir, name) do
    path = Path.join(dir, name)

    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime}} ->
        %{name: name, path: path, size: size, modified_at: DateTime.from_unix!(mtime)}

      {:error, _reason} ->
        %{name: name, path: path, size: 0, modified_at: nil}
    end
  end

  @doc """
  Safely resolves a single recording file for streaming. Rejects path traversal
  and anything outside the issue's recordings directory.
  """
  @spec fetch(String.t(), String.t()) ::
          {:ok, %{path: Path.t(), content_type: String.t()}} | {:error, term()}
  def fetch(issue_identifier, filename) when is_binary(issue_identifier) and is_binary(filename) do
    with {:ok, dir} <- directory(issue_identifier),
         :ok <- validate_filename(filename),
         {:ok, canonical_dir} <- PathSafety.canonicalize(dir),
         {:ok, canonical_path} <- PathSafety.canonicalize(Path.join(dir, filename)),
         :ok <- ensure_within(canonical_dir, canonical_path),
         :ok <- ensure_regular_file(canonical_path) do
      {:ok, %{path: canonical_path, content_type: content_type(filename)}}
    end
  end

  defp validate_filename(filename) do
    cond do
      filename in ["", ".", ".."] -> {:error, :invalid_filename}
      String.contains?(filename, ["/", "\\", "\0"]) -> {:error, :invalid_filename}
      not recording_file?(filename) -> {:error, :invalid_filename}
      true -> :ok
    end
  end

  defp ensure_within(dir, path) do
    if path == dir or String.starts_with?(path, dir <> "/") do
      :ok
    else
      {:error, :path_outside_recordings_dir}
    end
  end

  defp ensure_regular_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, :not_a_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recording_file?(name) do
    downcased = String.downcase(name)
    Enum.any?(@recording_extensions, &String.ends_with?(downcased, &1))
  end

  defp content_type(name) do
    case name |> Path.extname() |> String.downcase() do
      ".webm" -> "video/webm"
      ".mkv" -> "video/x-matroska"
      _ -> "video/mp4"
    end
  end
end

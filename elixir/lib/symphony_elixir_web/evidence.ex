defmodule SymphonyElixirWeb.Evidence do
  @moduledoc false

  @spec files_for_issue(String.t() | nil) :: [map()]
  def files_for_issue(issue_identifier) when is_binary(issue_identifier) do
    with root when is_binary(root) <- root(),
         true <- File.dir?(root),
         {:ok, filenames} <- File.ls(root) do
      filenames
      |> Enum.filter(&evidence_file_for_issue?(&1, issue_identifier))
      |> Enum.sort()
      |> Enum.map(&artifact(root, &1))
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  def files_for_issue(_issue_identifier), do: []

  @spec file_path(String.t()) :: {:ok, Path.t()} | :error
  def file_path(filename) when is_binary(filename) do
    with true <- safe_filename?(filename),
         root when is_binary(root) <- root(),
         path <- Path.join(root, filename),
         true <- File.regular?(path) do
      {:ok, path}
    else
      _ -> :error
    end
  end

  def file_path(_filename), do: :error

  @spec content_type(String.t()) :: String.t()
  def content_type(filename) when is_binary(filename) do
    case String.downcase(Path.extname(filename)) do
      ".mp4" -> "video/mp4"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".log" -> "text/plain"
      ".txt" -> "text/plain"
      ".json" -> "application/json"
      _ -> "application/octet-stream"
    end
  end

  defp artifact(root, filename) do
    path = Path.join(root, filename)

    with true <- File.regular?(path),
         {:ok, stat} <- File.stat(path) do
      %{
        filename: filename,
        href: "/evidence/#{URI.encode(filename, &URI.char_unreserved?/1)}",
        kind: artifact_kind(filename),
        size_bytes: stat.size
      }
    else
      _ -> nil
    end
  end

  defp evidence_file_for_issue?(filename, issue_identifier) do
    safe_filename?(filename) and String.starts_with?(filename, issue_identifier)
  end

  defp safe_filename?(filename) do
    filename == Path.basename(filename) and filename not in ["", ".", ".."]
  end

  defp artifact_kind(filename) do
    case String.downcase(Path.extname(filename)) do
      ".mp4" -> "video"
      ".png" -> "image"
      ".jpg" -> "image"
      ".jpeg" -> "image"
      ".log" -> "log"
      ".txt" -> "text"
      ".json" -> "json"
      _ -> "file"
    end
  end

  defp root do
    cond do
      evidence_root = present_env("SYMPHONY_EVIDENCE_ROOT") ->
        Path.expand(evidence_root)

      instance_root = present_env("SYMPHONY_INSTANCE_ROOT") ->
        instance_root |> Path.join("evidence") |> Path.expand()

      true ->
        nil
    end
  end

  defp present_env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end
end

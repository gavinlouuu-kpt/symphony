defmodule SymphonyElixirWeb.RecordingController do
  @moduledoc """
  Lists and streams virtual-desktop recordings captured for an issue so they can
  be replayed from the dashboard for demo and review.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Recordings

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, %{"issue_identifier" => issue_identifier}) do
    case Recordings.list(issue_identifier) do
      {:ok, recordings} ->
        json(conn, %{
          issue_identifier: issue_identifier,
          recordings: Enum.map(recordings, &recording_json(issue_identifier, &1))
        })

      {:error, reason} ->
        conn
        |> put_status(404)
        |> json(%{error: %{code: "recordings_unavailable", message: to_string(reason)}})
    end
  end

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"issue_identifier" => issue_identifier, "filename" => filename}) do
    case Recordings.fetch(issue_identifier, filename) do
      {:ok, %{path: path, content_type: content_type}} ->
        conn
        |> put_resp_content_type(content_type)
        |> Conn.send_file(200, path)

      {:error, _reason} ->
        send_resp(conn, 404, "Not Found")
    end
  end

  defp recording_json(issue_identifier, recording) do
    %{
      name: recording.name,
      size: recording.size,
      modified_at: modified_at_iso8601(recording.modified_at),
      url: "/api/v1/#{issue_identifier}/recordings/#{recording.name}"
    }
  end

  defp modified_at_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp modified_at_iso8601(_modified_at), do: nil
end

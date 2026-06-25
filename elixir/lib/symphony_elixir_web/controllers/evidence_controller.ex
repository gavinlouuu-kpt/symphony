defmodule SymphonyElixirWeb.EvidenceController do
  @moduledoc """
  Serves local evidence artifacts captured by a project instance.
  """

  use Phoenix.Controller, formats: []

  alias Plug.Conn
  alias SymphonyElixirWeb.Evidence

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"filename" => filename}) do
    case Evidence.file_path(filename) do
      {:ok, path} ->
        conn
        |> put_resp_content_type(Evidence.content_type(filename))
        |> put_resp_header("cache-control", "no-store")
        |> send_file(200, path)

      :error ->
        send_resp(conn, 404, "Not Found")
    end
  end
end

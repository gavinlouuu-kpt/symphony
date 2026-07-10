defmodule SymphonyElixirWeb.OpenClawIntakeController do
  @moduledoc """
  Authenticated OpenClaw intake API for creating GitHub issues.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Config
  alias SymphonyElixir.OpenClaw.Intake

  @spec create_issue(Conn.t(), map()) :: Conn.t()
  def create_issue(conn, params) do
    with :ok <- authorize(conn),
         {:ok, result} <- Intake.create_issue(params) do
      conn
      |> put_status(201)
      |> json(issue_payload(result))
    else
      {:error, :unauthorized_openclaw_intake} ->
        error_response(conn, 401, "unauthorized", "Invalid OpenClaw intake token")

      {:error, :openclaw_intake_disabled} ->
        error_response(conn, 403, "openclaw_intake_disabled", "OpenClaw issue intake is disabled")

      {:error, :openclaw_intake_requires_github_tracker} ->
        error_response(conn, 409, "github_tracker_required", "OpenClaw issue intake requires GitHub tracker mode")

      {:error, :missing_issue_title} ->
        error_response(conn, 422, "missing_issue_title", "Issue title is required")

      {:error, reason} ->
        error_response(conn, 502, "github_issue_create_failed", inspect(reason))
    end
  end

  defp authorize(conn) do
    token = Config.settings!().openclaw.intake_token

    if valid_bearer_token?(conn, token) do
      :ok
    else
      {:error, :unauthorized_openclaw_intake}
    end
  end

  defp valid_bearer_token?(conn, token) when is_binary(token) and token != "" do
    case Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> provided | _] -> secure_compare(provided, token)
      _ -> false
    end
  end

  defp valid_bearer_token?(_conn, _token), do: false

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false

  defp issue_payload(%{issue: issue, message: message}) do
    %{
      ok: true,
      message: message,
      issue: %{
        id: issue.id,
        identifier: issue.identifier,
        title: issue.title,
        state: issue.state,
        url: issue.url,
        labels: issue.labels
      }
    }
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{ok: false, error: %{code: code, message: message}})
  end
end

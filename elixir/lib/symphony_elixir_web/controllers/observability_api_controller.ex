defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec events(Conn.t(), map()) :: Conn.t()
  def events(conn, %{"issue_identifier" => issue_identifier}) do
    json(conn, %{issue_identifier: issue_identifier, events: Presenter.events_payload(issue_identifier)})
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec console(Conn.t(), map()) :: Conn.t()
  def console(conn, params) do
    request =
      %{
        target: Map.get(params, "target"),
        issue_identifier: Map.get(params, "issue_identifier"),
        body: Map.get(params, "body")
      }
      |> maybe_put_retained_sandbox()

    case Orchestrator.review_console_message(orchestrator(), request) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp maybe_put_retained_sandbox(%{target: "reviewer", issue_identifier: issue_identifier} = request)
       when is_binary(issue_identifier) do
    case retained_sandbox_for_issue(issue_identifier) do
      nil -> request
      retained_sandbox -> Map.put(request, :retained_sandbox, retained_sandbox)
    end
  end

  defp maybe_put_retained_sandbox(request), do: request

  defp retained_sandbox_for_issue(issue_identifier) do
    case Presenter.state_payload(orchestrator(), snapshot_timeout_ms()) do
      %{sandboxes: sandboxes} when is_list(sandboxes) ->
        Enum.find(sandboxes, fn sandbox_entry ->
          Map.get(sandbox_entry, :issue_identifier) == issue_identifier and
            Map.get(sandbox_entry, :issue_status) in ["retained", "human_review"]
        end)

      _ ->
        nil
    end
  end
end

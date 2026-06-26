defmodule SymphonyElixirWeb.IssueCreatorLive do
  @moduledoc """
  Private dashboard workflow for shaping feature/fix requests into Linear issues.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.IssueIntake
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:sessions, IssueIntake.list())
      |> assign(:selected_id, latest_session_id())
      |> assign(:error, nil)

    if connected?(socket), do: ObservabilityPubSub.subscribe()

    {:ok, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("start_intake", %{"intake" => params}, socket) do
    case IssueIntake.start_session(params) do
      {:ok, session} ->
        {:noreply, socket |> refresh(session.id) |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, error_message(reason))}
    end
  end

  def handle_event("select_session", %{"id" => id}, socket) do
    {:noreply, socket |> refresh(parse_id(id)) |> assign(:error, nil)}
  end

  def handle_event("send_message", %{"message" => %{"body" => body, "session_id" => session_id}}, socket) do
    case IssueIntake.append_message(session_id, body) do
      {:ok, session} ->
        {:noreply, socket |> refresh(session.id) |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, error_message(reason))}
    end
  end

  def handle_event("create_issue", %{"id" => id}, socket) do
    case IssueIntake.create_linear_issue(id) do
      {:ok, session} ->
        {:noreply, socket |> refresh(session.id) |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, error_message(reason))}
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :selected_session, selected_session(assigns.sessions, assigns.selected_id))

    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Planning</p>
            <h1 class="hero-title">Issue Creator</h1>
            <p class="hero-copy">
              Discuss a feature or fix, scan the configured repository, shape the task, and create a Linear issue for the project loop.
            </p>
          </div>

          <div class="status-stack">
            <a class="nav-pill" href="/">Dashboard</a>
          </div>
        </div>
      </header>

      <section class="project-panel">
        <div class="project-panel-header">
          <div>
            <p class="eyebrow">Project</p>
            <h2 class="project-title"><%= project_title(@payload) %></h2>
          </div>
          <span class="mono muted"><%= project_repo(@payload) %></span>
        </div>
      </section>

      <section :if={@error} class="error-card">
        <h2 class="error-title">Issue creator needs attention</h2>
        <p class="error-copy"><%= @error %></p>
      </section>

      <section class="issue-creator-grid">
        <div class="section-card intake-panel">
          <div class="section-header">
            <div>
              <h2 class="section-title">New request</h2>
              <p class="section-copy">Start with the raw thing you want fixed or built.</p>
            </div>
          </div>

          <.form for={%{}} as={:intake} phx-submit="start_intake" class="intake-form">
            <label class="console-field">
              <span>Type</span>
              <select name="intake[kind]">
                <option value="feature">Feature</option>
                <option value="fix">Fix</option>
                <option value="chore">Chore</option>
              </select>
            </label>

            <label class="console-field">
              <span>Title</span>
              <input name="intake[title]" type="text" placeholder="Multi prompt annotation for SAM2 backend" />
            </label>

            <label class="console-field">
              <span>Request</span>
              <textarea name="intake[body]" rows="8" placeholder="Describe the workflow, current behavior, expected behavior, and constraints."></textarea>
            </label>

            <button type="submit">Scan and Draft</button>
          </.form>

          <div class="session-list">
            <h3>Drafts</h3>
            <%= if @sessions == [] do %>
              <p class="empty-state">No intake drafts yet.</p>
            <% else %>
              <button
                :for={session <- @sessions}
                type="button"
                class={session_button_class(session, @selected_id)}
                phx-click="select_session"
                phx-value-id={session.id}
              >
                <span><%= session.title %></span>
                <span class="mono"><%= session.status %></span>
              </button>
            <% end %>
          </div>
        </div>

        <div class="section-card intake-panel">
          <%= if @selected_session do %>
            <div class="section-header">
              <div>
                <h2 class="section-title"><%= @selected_session.title %></h2>
                <p class="section-copy"><%= @selected_session.kind %> · <%= @selected_session.status %></p>
              </div>
              <button
                :if={is_nil(@selected_session.created_issue)}
                type="button"
                phx-click="create_issue"
                phx-value-id={@selected_session.id}
              >
                Create Linear Issue
              </button>
            </div>

            <div :if={@selected_session.created_issue} class="created-issue-banner">
              <span>Created</span>
              <a href={external_url(@selected_session.created_issue.url)} target="_blank" rel="noopener noreferrer">
                <%= @selected_session.created_issue.identifier %>
              </a>
              <span class="mono"><%= @selected_session.created_issue.state || "n/a" %></span>
            </div>

            <div class="scan-summary">
              <h3>Repo Scan</h3>
              <%= if @selected_session.scan do %>
                <dl class="scan-grid">
                  <div>
                    <dt>Files</dt>
                    <dd class="numeric"><%= @selected_session.scan.file_count %></dd>
                  </div>
                  <div>
                    <dt>Languages</dt>
                    <dd><%= list_text(@selected_session.scan.languages) %></dd>
                  </div>
                  <div>
                    <dt>Validation</dt>
                    <dd><%= list_text(@selected_session.scan.test_hints) %></dd>
                  </div>
                </dl>
              <% else %>
                <p class="empty-state">Scan is pending or unavailable. The draft can still be completed from discussion.</p>
              <% end %>
            </div>

            <div class="intake-chat">
              <h3>Discussion</h3>
              <article :for={message <- display_messages(@selected_session.messages)} class={"console-message console-message-#{message.role}"}>
                <header>
                  <span class="console-role"><%= role_label(message.role) %></span>
                  <span class="mono muted"><%= DateTime.to_iso8601(message.created_at) %></span>
                </header>
                <p><%= message.body %></p>
              </article>
            </div>

            <.form for={%{}} as={:message} phx-submit="send_message" class="intake-message-form">
              <input type="hidden" name="message[session_id]" value={@selected_session.id} />
              <label class="console-field">
                <span>Reply</span>
                <textarea name="message[body]" rows="4" placeholder="Add acceptance criteria, affected paths, roles, data requirements, edge cases, or validation commands."></textarea>
              </label>
              <button type="submit">Update Draft</button>
            </.form>

            <div class="draft-panel">
              <h3>Task Draft</h3>
              <pre class="code-panel"><%= @selected_session.draft %></pre>
            </div>
          <% else %>
            <p class="empty-state">Start a request to scan the repository and build an issue draft.</p>
          <% end %>
        </div>
      </section>
    </section>
    """
  end

  defp refresh(socket, selected_id \\ nil) do
    sessions = IssueIntake.list()
    selected_id = selected_id || socket.assigns[:selected_id] || latest_session_id(sessions)

    socket
    |> assign(:payload, load_payload())
    |> assign(:sessions, sessions)
    |> assign(:selected_id, selected_id)
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp latest_session_id(sessions \\ IssueIntake.list())
  defp latest_session_id([session | _]), do: session.id
  defp latest_session_id(_sessions), do: nil

  defp selected_session(sessions, selected_id), do: Enum.find(sessions, &(&1.id == selected_id))
  defp display_messages(messages), do: messages |> Enum.reverse() |> Enum.take(-20)
  defp role_label("user"), do: "You"
  defp role_label("assistant"), do: "Planner"
  defp role_label(role), do: role

  defp session_button_class(session, selected_id) do
    base = "session-button"
    if session.id == selected_id, do: "#{base} session-button-active", else: base
  end

  defp project_title(%{project: project}) when is_map(project) do
    Map.get(project, :instance_id) || Map.get(project, :project_slug) || "unknown project"
  end

  defp project_title(_payload), do: "unknown project"

  defp project_repo(%{project: %{source_repo_url: repo}}) when is_binary(repo) and repo != "", do: repo
  defp project_repo(_payload), do: "n/a"
  defp list_text([]), do: "n/a"
  defp list_text(values) when is_list(values), do: Enum.join(values, ", ")

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_id(value) when is_integer(value), do: value
  defp parse_id(_value), do: nil

  defp external_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> url
      _ -> nil
    end
  end

  defp external_url(_url), do: nil

  defp error_message(:missing_title), do: "Add a title before starting the intake."
  defp error_message(:missing_body), do: "Add enough request detail before continuing."
  defp error_message(:session_not_found), do: "That intake draft is no longer available."
  defp error_message(:project_not_found), do: "The configured Linear project could not be resolved."
  defp error_message(:team_not_found), do: "The configured Linear project has no team available for issue creation."
  defp error_message(:missing_linear_project_slug), do: "The workflow is missing a Linear project slug."
  defp error_message(reason), do: "Request failed: #{inspect(reason)}"

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end

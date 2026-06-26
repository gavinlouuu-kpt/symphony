defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Orchestrator, ReviewConsole}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:console_messages, ReviewConsole.list())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:console_messages, ReviewConsole.list())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("console_send", %{"console" => params}, socket) do
    payload = socket.assigns.payload
    issue_identifier = normalize_console_param(params["issue_identifier"])
    target = normalize_console_target(params["target"])
    body = normalize_console_param(params["body"])

    cond do
      payload[:error] ->
        {:noreply, socket}

      issue_identifier == "" or body == "" ->
        {:noreply, assign(socket, :console_messages, ReviewConsole.list())}

      true ->
        :ok = append_console_message(issue_identifier, target, "human", body)

        response =
          case Orchestrator.review_console_message(orchestrator(), %{
                 issue_identifier: issue_identifier,
                 target: target,
                 body: body
               }) do
            {:ok, %{role: role, body: response_body}} ->
              {role, response_body}

            {:error, :unavailable} ->
              {"orchestrator", "The orchestrator is unavailable."}
          end

        {role, response_body} = response
        :ok = append_console_message(issue_identifier, target, role, response_body)

        {:noreply,
         socket
         |> assign(:payload, load_payload())
         |> assign(:console_messages, ReviewConsole.list())
         |> assign(:now, DateTime.utc_now())}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              <%= dashboard_title(@payload) %>
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="project-panel">
          <div class="project-panel-header">
            <p class="eyebrow">Project</p>
            <h2 class="project-title"><%= project_name(@payload.project) %></h2>
          </div>

          <dl class="project-grid">
            <div>
              <dt>Instance</dt>
              <dd class="mono"><%= project_value(@payload.project, :instance_id) %></dd>
            </div>
            <div>
              <dt>Linear</dt>
              <dd>
                <%= if @payload.project[:project_url] do %>
                  <a href={@payload.project.project_url} target="_blank" rel="noopener noreferrer">
                    <%= project_value(@payload.project, :project_slug) %>
                  </a>
                <% else %>
                  <span class="mono"><%= project_value(@payload.project, :project_slug) %></span>
                <% end %>
              </dd>
            </div>
            <div>
              <dt>Repository</dt>
              <dd>
                <%= if @payload.project[:source_repo_url] do %>
                  <a href={@payload.project.source_repo_url} target="_blank" rel="noopener noreferrer">
                    <%= repo_label(@payload.project.source_repo_url) %>
                  </a>
                <% else %>
                  <span class="muted">n/a</span>
                <% end %>
              </dd>
            </div>
            <div>
              <dt>Branch</dt>
              <dd class="mono"><%= project_value(@payload.project, :source_repo_branch) %></dd>
            </div>
            <div>
              <dt>Worker</dt>
              <dd class="mono"><%= project_value(@payload.project, :worker_provider) %></dd>
            </div>
            <div>
              <dt>CUA host</dt>
              <dd class="mono"><%= project_value(@payload.project, :cua_host) %></dd>
            </div>
            <div>
              <dt>Workspace root</dt>
              <dd class="mono project-path"><%= project_value(@payload.project, :workspace_root) %></dd>
            </div>
          </dl>
        </section>

        <section class="section-card review-console">
          <div class="section-header">
            <div>
              <h2 class="section-title">Review console</h2>
              <p class="section-copy">Private issue-scoped messages to the orchestrator or next reviewer phase.</p>
            </div>
          </div>

          <.form for={%{}} as={:console} phx-submit="console_send" class="console-form">
            <label class="console-field">
              <span>Issue</span>
              <select name="console[issue_identifier]">
                <option :for={identifier <- console_issue_options(@payload)} value={identifier}>
                  <%= identifier %>
                </option>
              </select>
            </label>

            <label class="console-field">
              <span>Target</span>
              <select name="console[target]">
                <option value="orchestrator">Orchestrator</option>
                <option value="reviewer">Reviewer</option>
              </select>
            </label>

            <label class="console-field console-message-field">
              <span>Message</span>
              <textarea name="console[body]" rows="3" placeholder="Ask for status, request a reviewer check, or leave a note for human review."></textarea>
            </label>

            <button type="submit">Send</button>
          </.form>

          <div class="console-log">
            <%= if @console_messages == [] do %>
              <p class="empty-state">No console messages yet.</p>
            <% else %>
              <article :for={message <- console_messages_for_display(@console_messages)} class={"console-message console-message-#{message.role}"}>
                <header>
                  <span class="console-role"><%= console_role_label(message.role) %></span>
                  <span class="mono muted"><%= message.issue_identifier %> · <%= message.target %> · <%= DateTime.to_iso8601(message.created_at) %></span>
                </header>
                <p><%= message.body %></p>
              </article>
            <% end %>
          </div>
        </section>

        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail">Issues paused for operator input or approval.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">CUA sandboxes</h2>
              <p class="section-copy">Live sandbox desktops and service endpoints retained with their issue until terminal cleanup.</p>
            </div>
          </div>

          <%= if @payload.sandboxes == [] do %>
            <p class="empty-state">No active CUA sandboxes.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 1040px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Sandbox</th>
                    <th>Issue status</th>
                    <th>Evidence</th>
                    <th>Workspace</th>
                    <th>Worker</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.sandboxes}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <.sandbox_links sandbox={entry.sandbox} />
                    </td>
                    <td>
                      <span class={state_badge_class(entry.issue_status)}>
                        <%= entry.issue_status %>
                      </span>
                    </td>
                    <td>
                      <.evidence_links evidence={Map.get(entry, :evidence, [])} />
                    </td>
                    <td>
                      <span class="mono muted workspace-text"><%= entry.workspace_path || "n/a" %></span>
                    </td>
                    <td>
                      <span class="mono muted workspace-text"><%= entry.worker_host || "n/a" %></span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 11rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Sandbox</th>
                    <th>Phase</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <.sandbox_links sandbox={entry.sandbox} />
                    </td>
                    <td>
                      <span class={state_badge_class(entry.phase)}>
                        <%= entry.phase %>
                      </span>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Blocked sessions</h2>
              <p class="section-copy">Issues paused because Codex requested operator input or approval.</p>
            </div>
          </div>

          <%= if @payload.blocked == [] do %>
            <p class="empty-state">No blocked sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Sandbox</th>
                    <th>Phase</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Blocked at</th>
                    <th>Last update</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <.sandbox_links sandbox={entry.sandbox} />
                    </td>
                    <td>
                      <span class={state_badge_class(entry.phase)}>
                        <%= entry.phase %>
                      </span>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state || "Blocked")}>
                        <%= entry.state || "Blocked" %>
                      </span>
                    </td>
                    <td>
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="Copy ID"
                          data-copy={entry.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          Copy ID
                        </button>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </td>
                    <td class="mono"><%= entry.blocked_at || "n/a" %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Sandbox</th>
                    <th>Phase</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <.sandbox_links sandbox={entry.sandbox} />
                    </td>
                    <td>
                      <span class={state_badge_class(entry.phase)}>
                        <%= entry.phase %>
                      </span>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp dashboard_title(%{project: project}) when is_map(project) do
    case project_name(project) do
      "unknown project" -> "Operations Dashboard"
      name -> "#{name} Dashboard"
    end
  end

  defp dashboard_title(_payload), do: "Operations Dashboard"

  defp project_name(project) when is_map(project) do
    Map.get(project, :instance_id) || Map.get(project, :project_slug) || repo_name(Map.get(project, :source_repo_url)) ||
      "unknown project"
  end

  defp project_name(_project), do: "unknown project"

  defp project_value(project, key) when is_map(project) do
    case Map.get(project, key) do
      value when is_binary(value) and value != "" -> value
      value when is_integer(value) -> Integer.to_string(value)
      value when is_atom(value) -> Atom.to_string(value)
      _ -> "n/a"
    end
  end

  defp project_value(_project, _key), do: "n/a"

  defp repo_label(repo_url) when is_binary(repo_url) and repo_url != "" do
    repo_name(repo_url) || repo_url
  end

  defp repo_label(_repo_url), do: "n/a"

  defp repo_name(repo_url) when is_binary(repo_url) and repo_url != "" do
    repo_url
    |> String.trim_trailing("/")
    |> String.split("/")
    |> Enum.take(-2)
    |> Enum.join("/")
    |> case do
      "" -> nil
      label -> label
    end
  end

  defp repo_name(_repo_url), do: nil

  defp console_issue_options(%{running: running, retrying: retrying, blocked: blocked, sandboxes: sandboxes}) do
    [running, retrying, blocked, sandboxes]
    |> List.flatten()
    |> Enum.flat_map(fn
      %{issue_identifier: identifier} when is_binary(identifier) and identifier != "" -> [identifier]
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp console_issue_options(_payload), do: []

  defp console_messages_for_display(messages) when is_list(messages) do
    messages
    |> Enum.take(30)
    |> Enum.reverse()
  end

  defp console_role_label("human"), do: "You"
  defp console_role_label("reviewer"), do: "Reviewer"
  defp console_role_label("orchestrator"), do: "Orchestrator"
  defp console_role_label(role), do: role

  defp normalize_console_param(value) when is_binary(value), do: String.trim(value)
  defp normalize_console_param(_value), do: ""

  defp normalize_console_target("reviewer"), do: "reviewer"
  defp normalize_console_target(_target), do: "orchestrator"

  defp append_console_message(issue_identifier, target, role, body) do
    case ReviewConsole.append(%{
           issue_identifier: issue_identifier,
           target: target,
           role: role,
           body: body
         }) do
      {:ok, _message} -> :ok
      {:error, :unavailable} -> :ok
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  attr(:sandbox, :map, default: nil)

  defp sandbox_links(assigns) do
    assigns =
      assigns
      |> assign(:name, sandbox_value(assigns.sandbox, :name) || "n/a")
      |> assign(:status, sandbox_value(assigns.sandbox, :status) || sandbox_value(assigns.sandbox, :source))
      |> assign(:novnc_href, external_issue_url(sandbox_value(assigns.sandbox, :novnc_url)))
      |> assign(:api_href, external_issue_url(sandbox_value(assigns.sandbox, :api_url)))
      |> assign(:host, sandbox_value(assigns.sandbox, :host))
      |> assign(:ssh_target, sandbox_value(assigns.sandbox, :ssh_target))
      |> assign(:lifecycle, sandbox_lifecycle_label(sandbox_value(assigns.sandbox, :lifecycle)))

    ~H"""
    <%= if @sandbox do %>
      <div class="sandbox-stack">
        <span class="mono sandbox-name"><%= @name %></span>
        <span :if={@status || @lifecycle} class="muted">
          <%= Enum.reject([@status, @lifecycle], &is_nil/1) |> Enum.join(" · ") %>
        </span>
        <span :if={@host} class="mono muted sandbox-host"><%= @host %></span>
        <span :if={@ssh_target} class="mono muted sandbox-host"><%= @ssh_target %></span>
        <span class="sandbox-actions">
          <a :if={@novnc_href} class="issue-link sandbox-link" href={@novnc_href} target="_blank" rel="noopener noreferrer">Open noVNC</a>
          <a :if={@api_href} class="issue-link sandbox-link" href={@api_href} target="_blank" rel="noopener noreferrer">API</a>
        </span>
      </div>
    <% else %>
      <span class="muted">n/a</span>
    <% end %>
    """
  end

  attr(:evidence, :list, default: [])

  defp evidence_links(assigns) do
    assigns = assign(assigns, :evidence, assigns.evidence || [])

    ~H"""
    <%= if @evidence == [] do %>
      <span class="muted">n/a</span>
    <% else %>
      <span class="sandbox-actions">
        <a
          :for={artifact <- @evidence}
          class="issue-link sandbox-link"
          href={artifact.href}
          target="_blank"
          rel="noopener noreferrer"
        >
          <%= artifact_label(artifact) %>
        </a>
      </span>
    <% end %>
    """
  end

  defp sandbox_value(nil, _key), do: nil

  defp sandbox_value(sandbox, key) when is_map(sandbox) do
    Map.get(sandbox, key) || Map.get(sandbox, to_string(key))
  end

  defp artifact_label(artifact) when is_map(artifact) do
    kind = Map.get(artifact, :kind) || Map.get(artifact, "kind") || "file"
    filename = Map.get(artifact, :filename) || Map.get(artifact, "filename") || kind

    case kind do
      "video" -> "video"
      "image" -> "image"
      "log" -> "log"
      _ -> filename
    end
  end

  defp sandbox_lifecycle_label("delete_on_terminal"), do: "closes when terminal"
  defp sandbox_lifecycle_label("preserve"), do: "kept for inspection"
  defp sandbox_lifecycle_label(value) when is_binary(value) and value != "", do: value
  defp sandbox_lifecycle_label(_value), do: nil

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end

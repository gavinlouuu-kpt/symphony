defmodule SymphonyElixir.Github.Client do
  @moduledoc """
  Thin GitHub Issues REST client for tracker polling.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @default_endpoint "https://api.github.com"
  @per_page 100

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    Config.settings!().tracker.active_states
    |> fetch_issues_by_states()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    with {:ok, repo} <- configured_repo(),
         {:ok, issues} <- fetch_repo_issues(repo, github_state_param(state_names), 1, []) do
      {:ok, filter_issues_by_states(issues, state_names)}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    with {:ok, repo} <- configured_repo() do
      issue_ids
      |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
        case issue_number(issue_id) do
          {:ok, number} ->
            case fetch_issue(repo, number) do
              {:ok, nil} -> {:cont, {:ok, acc}}
              {:ok, %Issue{} = issue} -> {:cont, {:ok, [issue | acc]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          :error ->
            {:cont, {:ok, acc}}
        end
      end)
      |> case do
        {:ok, issues} -> {:ok, Enum.reverse(issues)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, repo} <- configured_repo(),
         {:ok, number} <- parse_issue_number(issue_id),
         {:ok, _body} <- request(:post, issue_comments_url(repo, number), json: %{body: body}) do
      :ok
    end
  end

  @spec create_issue(String.t(), String.t()) :: {:ok, Issue.t()} | {:error, term()}
  @spec create_issue(String.t(), String.t(), [String.t()]) :: {:ok, Issue.t()} | {:error, term()}
  def create_issue(title, body, labels \\ [])
      when is_binary(title) and is_binary(body) and is_list(labels) do
    with {:ok, repo} <- configured_repo(),
         {:ok, response} <-
           request(:post, repo_issues_url(repo),
             json: %{
               title: title,
               body: body,
               labels: labels
             }
           ),
         %Issue{} = issue <- normalize_issue(response, repo) do
      {:ok, issue}
    else
      nil -> {:error, :invalid_github_issue_response}
      error -> error
    end
  end

  @spec add_issue_labels(String.t(), [String.t()]) :: :ok | {:error, term()}
  def add_issue_labels(issue_id, labels) when is_binary(issue_id) and is_list(labels) do
    with {:ok, repo} <- configured_repo(),
         {:ok, number} <- parse_issue_number(issue_id),
         {:ok, _body} <-
           request(:post, issue_labels_url(repo, number), json: %{labels: labels}) do
      :ok
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, repo} <- configured_repo(),
         {:ok, number} <- parse_issue_number(issue_id),
         {:ok, github_state} <- github_mutation_state(state_name),
         {:ok, _body} <- request(:patch, issue_url(repo, number), json: %{state: github_state}) do
      :ok
    end
  end

  defp configured_repo do
    case Config.settings!().tracker.project_slug do
      slug when is_binary(slug) ->
        slug
        |> String.trim()
        |> String.split("/", parts: 2)
        |> case do
          [owner, repo] when owner != "" and repo != "" -> {:ok, %{owner: owner, repo: repo}}
          _ -> {:error, :missing_github_repository}
        end

      _ ->
        {:error, :missing_github_repository}
    end
  end

  defp fetch_repo_issues(repo, state, page, acc) do
    params = [state: state, per_page: @per_page, page: page]

    with {:ok, body} <- request(:get, repo_issues_url(repo), params: params) do
      issues =
        body
        |> normalize_issue_list(repo)

      updated_acc = acc ++ issues

      if is_list(body) and length(body) == @per_page do
        fetch_repo_issues(repo, state, page + 1, updated_acc)
      else
        {:ok, updated_acc}
      end
    end
  end

  defp fetch_issue(repo, number) when is_integer(number) do
    case request(:get, issue_url(repo, number)) do
      {:ok, body} -> {:ok, normalize_issue(body, repo)}
      {:error, {:github_api_status, 404}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(method, url), do: request(method, url, [])

  defp request(method, url, opts) when method in [:get, :post, :patch] do
    with {:ok, headers} <- github_headers() do
      opts = Keyword.merge([headers: headers, connect_options: [timeout: 30_000]], opts)

      case apply(Req, method, [url, opts]) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("GitHub request failed method=#{method} url=#{url} status=#{status} body=#{summarize_error_body(body)}")
          {:error, {:github_api_status, status}}

        {:error, reason} ->
          {:error, {:github_api_request, reason}}
      end
    end
  end

  defp github_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_github_api_token}

      token ->
        {:ok,
         [
           {"Authorization", "Bearer #{token}"},
           {"Accept", "application/vnd.github+json"},
           {"X-GitHub-Api-Version", "2022-11-28"},
           {"User-Agent", "symphony-elixir"}
         ]}
    end
  end

  defp repo_issues_url(repo), do: "#{api_endpoint()}/repos/#{repo.owner}/#{repo.repo}/issues"
  defp issue_url(repo, number), do: "#{repo_issues_url(repo)}/#{number}"
  defp issue_comments_url(repo, number), do: "#{issue_url(repo, number)}/comments"
  defp issue_labels_url(repo, number), do: "#{issue_url(repo, number)}/labels"

  defp api_endpoint do
    Config.settings!().tracker.endpoint || @default_endpoint
  end

  defp github_state_param(state_names) do
    normalized =
      state_names
      |> Enum.map(&normalize_state/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case normalized do
      ["open"] -> "open"
      ["closed"] -> "closed"
      _ -> "all"
    end
  end

  defp filter_issues_by_states(issues, state_names) do
    wanted =
      state_names
      |> Enum.map(&normalize_state/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    Enum.filter(issues, fn %Issue{state: state} ->
      MapSet.size(wanted) == 0 or MapSet.member?(wanted, normalize_state(state))
    end)
  end

  defp normalize_issue_list(body, repo) when is_list(body) do
    body
    |> Enum.map(&normalize_issue(&1, repo))
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_issue_list(_body, _repo), do: []

  defp normalize_issue(%{"pull_request" => _}, _repo), do: nil

  defp normalize_issue(%{"number" => number} = issue, repo) when is_integer(number) do
    %Issue{
      id: issue_id(repo, number),
      identifier: "GH-#{number}",
      title: issue["title"],
      description: issue["body"],
      state: issue["state"],
      url: issue["html_url"],
      labels: labels(issue["labels"]),
      assigned_to_worker: assigned_to_worker?(issue["assignees"]),
      created_at: parse_datetime(issue["created_at"]),
      updated_at: parse_datetime(issue["updated_at"])
    }
  end

  defp normalize_issue(_issue, _repo), do: nil

  defp issue_id(repo, number), do: "github:#{repo.owner}/#{repo.repo}##{number}"

  defp issue_number(issue_id) when is_binary(issue_id) do
    parse_issue_number(issue_id)
    |> case do
      {:ok, number} -> {:ok, number}
      {:error, _reason} -> :error
    end
  end

  defp issue_number(_issue_id), do: :error

  defp parse_issue_number(issue_id) when is_binary(issue_id) do
    case Regex.run(~r/(?:#|GH-)(\d+)$/i, String.trim(issue_id)) do
      [_, number] -> {:ok, String.to_integer(number)}
      _ -> {:error, :invalid_github_issue_id}
    end
  end

  defp github_mutation_state(state_name) do
    case normalize_state(state_name) do
      "closed" -> {:ok, "closed"}
      "done" -> {:ok, "closed"}
      "open" -> {:ok, "open"}
      "todo" -> {:ok, "open"}
      "in progress" -> {:ok, "open"}
      "rework" -> {:ok, "open"}
      _ -> {:error, :unsupported_github_issue_state}
    end
  end

  defp assigned_to_worker?(_assignees) do
    # GitHub routing is controlled by configured labels. Assignee matching can be added when needed.
    true
  end

  defp labels(labels) when is_list(labels) do
    labels
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> name
      name when is_binary(name) -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp labels(_labels), do: []

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: 2_000)
    |> String.slice(0, 2_000)
  end
end

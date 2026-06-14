defmodule SymphonyElixir.PullRequest do
  @moduledoc """
  Resolves the GitHub pull-request status for an issue workspace so the review
  phase of the container orchestrator can keep a desktop alive while its PR is
  open and reap it once the PR is merged or otherwise closed ("outdated").

  The default resolver shells out to the GitHub CLI (`gh pr view`) inside the
  workspace, which auto-detects the PR for the workspace's current branch. Tests
  (and alternate deployments) can inject a resolver via the
  `:pull_request_resolver` application env.
  """

  @type status :: :open | :merged | :closed | :none

  @doc """
  Returns the PR status for `workspace`:

    * `:open` — an open PR exists for the workspace branch;
    * `:merged` — the PR was merged;
    * `:closed` — the PR was closed without merging;
    * `:none` — no PR was found, or the status could not be determined.

  Errors resolve to `:none` so callers can treat "unknown" conservatively.
  """
  @spec status(Path.t()) :: status()
  def status(workspace) when is_binary(workspace) do
    resolver = Application.get_env(:symphony_elixir, :pull_request_resolver, &default_status/1)
    resolver.(workspace)
  end

  def status(_workspace), do: :none

  @doc "True when an open PR keeps the desktop in scope."
  @spec open?(status()) :: boolean()
  def open?(:open), do: true
  def open?(_status), do: false

  @doc "True when the PR is merged or closed and the desktop is safe to reap."
  @spec outdated?(status()) :: boolean()
  def outdated?(status) when status in [:merged, :closed], do: true
  def outdated?(_status), do: false

  defp default_status(workspace) do
    with true <- File.dir?(workspace),
         {output, 0} <- gh_pr_view(workspace),
         {:ok, %{"state" => state}} <- Jason.decode(output) do
      classify(state)
    else
      _ -> :none
    end
  end

  defp gh_pr_view(workspace) do
    case System.find_executable("gh") do
      nil ->
        {"gh not found", 127}

      executable ->
        System.cmd(executable, ["pr", "view", "--json", "state"],
          cd: workspace,
          stderr_to_stdout: true
        )
    end
  end

  defp classify(state) when is_binary(state) do
    case String.upcase(state) do
      "OPEN" -> :open
      "MERGED" -> :merged
      "CLOSED" -> :closed
      _ -> :none
    end
  end

  defp classify(_state), do: :none
end

defmodule SymphonyElixir.PullRequestTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.PullRequest

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "symphony-pr-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :pull_request_resolver)

      case previous_path do
        nil -> System.delete_env("PATH")
        value -> System.put_env("PATH", value)
      end

      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace, previous_path: previous_path}
  end

  test "open?/1 and outdated?/1 classify statuses" do
    assert PullRequest.open?(:open)
    refute PullRequest.open?(:merged)
    refute PullRequest.open?(:none)

    assert PullRequest.outdated?(:merged)
    assert PullRequest.outdated?(:closed)
    refute PullRequest.outdated?(:open)
    refute PullRequest.outdated?(:none)
  end

  test "status uses the injected resolver and guards non-binary workspaces", %{workspace: workspace} do
    Application.put_env(:symphony_elixir, :pull_request_resolver, fn ^workspace -> :open end)
    assert PullRequest.status(workspace) == :open

    Application.delete_env(:symphony_elixir, :pull_request_resolver)
    assert PullRequest.status(nil) == :none
    assert PullRequest.status(123) == :none
  end

  test "default resolver returns :none for a missing workspace" do
    assert PullRequest.status("/nonexistent/symphony/workspace") == :none
  end

  test "default resolver returns :none when gh is unavailable", %{workspace: workspace} do
    empty = Path.join(workspace, "empty-bin")
    File.mkdir_p!(empty)
    System.put_env("PATH", empty)

    assert PullRequest.status(workspace) == :none
  end

  test "default resolver classifies gh pr view output", %{workspace: workspace, previous_path: previous_path} do
    bin = Path.join(workspace, "bin")
    File.mkdir_p!(bin)
    fake_gh = Path.join(bin, "gh")

    File.write!(fake_gh, """
    #!/bin/sh
    if [ -f ./ghstate ]; then
      cat ./ghstate
      exit 0
    fi
    echo "no pull requests found"
    exit 1
    """)

    File.chmod!(fake_gh, 0o755)
    System.put_env("PATH", "#{bin}:#{previous_path}")

    state_file = Path.join(workspace, "ghstate")

    File.write!(state_file, ~s({"state":"OPEN"}))
    assert PullRequest.status(workspace) == :open

    File.write!(state_file, ~s({"state":"MERGED"}))
    assert PullRequest.status(workspace) == :merged

    File.write!(state_file, ~s({"state":"CLOSED"}))
    assert PullRequest.status(workspace) == :closed

    File.write!(state_file, ~s({"state":"DRAFT"}))
    assert PullRequest.status(workspace) == :none

    File.write!(state_file, ~s({"state":123}))
    assert PullRequest.status(workspace) == :none

    File.write!(state_file, "not json")
    assert PullRequest.status(workspace) == :none

    # No PR for the branch: gh exits non-zero.
    File.rm!(state_file)
    assert PullRequest.status(workspace) == :none
  end
end

defmodule SymphonyElixir.ContainerOrchestrator do
  @moduledoc """
  Orchestrates the lifecycle concerns of per-issue agent desktops around three
  responsibilities:

    * **setup** — inspect the issue's bind-mounted workspace, decide which
      reusable features (docker, make, browser, …) it needs, and install them
      into the container idempotently (`SymphonyElixir.ContainerFeatures`).
    * **debug** — collect a diagnostics snapshot (engine status, installed
      feature markers, recent container logs) for troubleshooting an agent that
      is misbehaving inside its desktop.
    * **review** — keep an issue's desktop alive while its pull request is open
      and reap it once the PR is merged or closed
      (`SymphonyElixir.ContainerRuntime` retention + reaper).

  `ContainerRuntime` owns the raw engine plumbing; this module is the policy
  layer that the agent runner (setup) and orchestrator poll loop (review) call.
  """

  require Logger

  alias SymphonyElixir.{Config, ContainerFeatures, ContainerRuntime}

  @doc """
  Setup phase: provision the features `workspace` needs into `container`.

  Best-effort — detection/installation failures are logged and returned but
  never abort the agent run. Returns `{:ok, result}` with `provisioned`,
  `skipped`, and `failed` feature ids, or `:noop` when there is nothing to do.
  """
  @spec setup(map() | nil, Path.t()) :: {:ok, ContainerFeatures.provision_result()} | :noop
  def setup(%{container_name: container_name}, workspace) when is_binary(workspace) do
    case Config.settings!().container.features do
      [] ->
        :noop

      configured_features ->
        case ContainerFeatures.resolve(configured_features, workspace) do
          [] ->
            :noop

          features ->
            ids = Enum.map(features, & &1.id)
            Logger.info("Setting up container features container_name=#{container_name} features=#{inspect(ids)}")
            {:ok, ContainerFeatures.provision(container_name, features, &ContainerRuntime.engine_exec/2)}
        end
    end
  end

  def setup(_container, _workspace), do: :noop

  @doc """
  Debug phase: gather a diagnostics snapshot for an issue's desktop container.
  """
  @spec diagnostics(String.t()) :: %{
          container_name: String.t(),
          status: String.t() | nil,
          features: [String.t()],
          logs: String.t() | nil
        }
  def diagnostics(issue_identifier) when is_binary(issue_identifier) do
    container_name = ContainerRuntime.container_name(issue_identifier)

    %{
      container_name: container_name,
      status: container_status(container_name),
      features: installed_features(container_name),
      logs: recent_logs(container_name)
    }
  end

  @doc """
  Review phase: reap retained desktops whose PRs are merged or closed. Issues in
  `active_identifiers` are never reaped. Returns the reaped identifiers.
  """
  @spec review([String.t()]) :: [String.t()]
  def review(active_identifiers) when is_list(active_identifiers) do
    ContainerRuntime.reap_retained_desktops(active_identifiers)
  end

  defp container_status(container_name) do
    case ContainerRuntime.engine_exec(container_name, "echo running") do
      {:ok, {output, 0}} -> output |> to_string() |> String.trim()
      {:ok, {_output, _status}} -> nil
      {:error, _reason} -> nil
    end
  end

  defp installed_features(container_name) do
    case ContainerRuntime.engine_exec(container_name, "ls -1 #{ContainerFeatures.marker_root()} 2>/dev/null || true") do
      {:ok, {output, 0}} ->
        output |> to_string() |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp recent_logs(container_name) do
    case ContainerRuntime.engine_exec(container_name, "tail -n 40 /var/log/symphony-agent-desktop.log 2>/dev/null || true") do
      {:ok, {output, 0}} ->
        case String.trim(to_string(output)) do
          "" -> nil
          logs -> logs
        end

      _ ->
        nil
    end
  end
end

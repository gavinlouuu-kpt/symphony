defmodule SymphonyElixir.Tailscale do
  @moduledoc """
  Resolves this node's Tailscale address so per-issue agent containers (and
  their noVNC desktops) can be reached from other devices on the tailnet,
  e.g. when operating Symphony on a remote dev server over Tailscale SSH.
  """

  require Logger

  @doc """
  Returns this node's primary Tailscale IPv4 address (`tailscale ip -4`).
  """
  @spec ipv4() :: {:ok, String.t()} | {:error, term()}
  def ipv4 do
    case run_tailscale(["ip", "-4"]) do
      {:ok, {output, 0}} ->
        first_address(output)

      {:ok, {output, status}} ->
        {:error, {:tailscale_command_failed, ["ip", "-4"], status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns this node's MagicDNS name (from `tailscale status --json`), without
  the trailing dot. Falls back on an error tuple when MagicDNS is unavailable.
  """
  @spec dns_name() :: {:ok, String.t()} | {:error, term()}
  def dns_name do
    case run_tailscale(["status", "--json"]) do
      {:ok, {output, 0}} ->
        parse_dns_name(output)

      {:ok, {output, status}} ->
        {:error, {:tailscale_command_failed, ["status", "--json"], status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Best host name to advertise to tailnet peers: the MagicDNS name when
  available, otherwise the Tailscale IPv4 address.
  """
  @spec advertise_host() :: {:ok, String.t()} | {:error, term()}
  def advertise_host do
    case dns_name() do
      {:ok, dns_name} -> {:ok, dns_name}
      {:error, _reason} -> ipv4()
    end
  end

  defp first_address(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> {:error, {:tailscale_no_ipv4, output}}
      address -> {:ok, address}
    end
  end

  defp parse_dns_name(output) do
    with {:ok, status} <- Jason.decode(output),
         dns_name when is_binary(dns_name) <- get_in(status, ["Self", "DNSName"]),
         trimmed when trimmed != "" <- String.trim_trailing(String.trim(dns_name), ".") do
      {:ok, trimmed}
    else
      _ -> {:error, {:tailscale_no_dns_name, output}}
    end
  end

  defp run_tailscale(args) do
    runner = Application.get_env(:symphony_elixir, :tailscale_command_runner, &default_command_runner/1)
    runner.(args)
  end

  defp default_command_runner(args) do
    case System.find_executable("tailscale") do
      nil ->
        {:error, :tailscale_not_found}

      executable ->
        {:ok, System.cmd(executable, args, stderr_to_stdout: true)}
    end
  end
end

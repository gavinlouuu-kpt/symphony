defmodule SymphonyElixir.TailscaleTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.Tailscale

  setup do
    on_exit(fn -> Application.delete_env(:symphony_elixir, :tailscale_command_runner) end)
    :ok
  end

  test "ipv4 returns the first address reported by the tailscale CLI" do
    Application.put_env(:symphony_elixir, :tailscale_command_runner, fn ["ip", "-4"] ->
      {:ok, {"100.64.0.7\n", 0}}
    end)

    assert {:ok, "100.64.0.7"} = Tailscale.ipv4()
  end

  test "ipv4 surfaces command failures and empty output" do
    Application.put_env(:symphony_elixir, :tailscale_command_runner, fn ["ip", "-4"] ->
      {:ok, {"Logged out.", 1}}
    end)

    assert {:error, {:tailscale_command_failed, ["ip", "-4"], 1, "Logged out."}} = Tailscale.ipv4()

    Application.put_env(:symphony_elixir, :tailscale_command_runner, fn ["ip", "-4"] ->
      {:ok, {"\n  \n", 0}}
    end)

    assert {:error, {:tailscale_no_ipv4, _output}} = Tailscale.ipv4()

    Application.put_env(:symphony_elixir, :tailscale_command_runner, fn _args ->
      {:error, :tailscale_not_found}
    end)

    assert {:error, :tailscale_not_found} = Tailscale.ipv4()
  end

  test "dns_name parses the MagicDNS name from tailscale status" do
    Application.put_env(:symphony_elixir, :tailscale_command_runner, fn ["status", "--json"] ->
      {:ok, {~s({"Self":{"DNSName":"dev-server.tail1234.ts.net."}}), 0}}
    end)

    assert {:ok, "dev-server.tail1234.ts.net"} = Tailscale.dns_name()
  end

  test "dns_name surfaces command failures and missing MagicDNS names" do
    Application.put_env(:symphony_elixir, :tailscale_command_runner, fn ["status", "--json"] ->
      {:ok, {"failed", 1}}
    end)

    assert {:error, {:tailscale_command_failed, ["status", "--json"], 1, "failed"}} = Tailscale.dns_name()

    Application.put_env(:symphony_elixir, :tailscale_command_runner, fn ["status", "--json"] ->
      {:ok, {"not json", 0}}
    end)

    assert {:error, {:tailscale_no_dns_name, "not json"}} = Tailscale.dns_name()

    Application.put_env(:symphony_elixir, :tailscale_command_runner, fn ["status", "--json"] ->
      {:ok, {~s({"Self":{"DNSName":"."}}), 0}}
    end)

    assert {:error, {:tailscale_no_dns_name, _output}} = Tailscale.dns_name()

    Application.put_env(:symphony_elixir, :tailscale_command_runner, fn _args ->
      {:error, :tailscale_not_found}
    end)

    assert {:error, :tailscale_not_found} = Tailscale.dns_name()
  end

  test "advertise_host prefers MagicDNS and falls back to the IPv4 address" do
    Application.put_env(:symphony_elixir, :tailscale_command_runner, fn
      ["status", "--json"] -> {:ok, {~s({"Self":{"DNSName":"dev-server.tail1234.ts.net."}}), 0}}
      ["ip", "-4"] -> {:ok, {"100.64.0.7\n", 0}}
    end)

    assert {:ok, "dev-server.tail1234.ts.net"} = Tailscale.advertise_host()

    Application.put_env(:symphony_elixir, :tailscale_command_runner, fn
      ["status", "--json"] -> {:ok, {"{}", 0}}
      ["ip", "-4"] -> {:ok, {"100.64.0.7\n", 0}}
    end)

    assert {:ok, "100.64.0.7"} = Tailscale.advertise_host()

    Application.put_env(:symphony_elixir, :tailscale_command_runner, fn _args ->
      {:error, :tailscale_not_found}
    end)

    assert {:error, :tailscale_not_found} = Tailscale.advertise_host()
  end

  test "default command runner shells out to the tailscale CLI found on PATH" do
    Application.delete_env(:symphony_elixir, :tailscale_command_runner)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-fake-tailscale-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    fake_tailscale = Path.join(test_root, "tailscale")

    File.write!(fake_tailscale, """
    #!/bin/sh
    if [ "$1" = "ip" ]; then
      echo "100.64.0.9"
    fi
    """)

    File.chmod!(fake_tailscale, 0o755)

    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    System.put_env("PATH", test_root)

    assert {:ok, "100.64.0.9"} = Tailscale.ipv4()

    empty_path = Path.join(test_root, "empty")
    File.mkdir_p!(empty_path)
    System.put_env("PATH", empty_path)

    assert {:error, :tailscale_not_found} = Tailscale.ipv4()
  end
end

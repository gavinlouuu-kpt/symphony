defmodule SymphonyElixir.ContainerFeaturesTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias SymphonyElixir.ContainerFeatures

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "symphony-features-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    {:ok, workspace: workspace}
  end

  test "builtin_features exposes the reusable catalog" do
    catalog = ContainerFeatures.builtin_features()

    assert Map.keys(catalog) |> Enum.sort() ==
             ["browser", "docker", "go", "make", "node", "python", "rust"]

    assert %{id: "make", install: install} = catalog["make"]
    assert is_list(install)
  end

  test "detect returns [] for missing or non-binary workspaces" do
    assert ContainerFeatures.detect("/nonexistent/symphony/workspace") == []
    assert ContainerFeatures.detect(nil) == []
    assert ContainerFeatures.detect(123) == []
  end

  test "detect recognizes make, docker, node, python, rust and go", %{workspace: workspace} do
    File.write!(Path.join(workspace, "Makefile"), "all:\n")
    File.write!(Path.join(workspace, "Dockerfile"), "FROM scratch\n")
    File.write!(Path.join(workspace, "package.json"), ~s({"name":"x"}))
    File.write!(Path.join(workspace, "requirements.txt"), "requests\n")
    File.write!(Path.join(workspace, "Cargo.toml"), "[package]\n")
    File.write!(Path.join(workspace, "go.mod"), "module x\n")

    detected = ContainerFeatures.detect(workspace)
    assert "make" in detected
    assert "docker" in detected
    assert "node" in detected
    assert "python" in detected
    assert "rust" in detected
    assert "go" in detected
    refute "browser" in detected
  end

  test "detect recognizes nested manifests one level deep", %{workspace: workspace} do
    File.mkdir_p!(Path.join(workspace, "sub"))
    File.write!(Path.join([workspace, "sub", "Makefile"]), "all:\n")
    File.write!(Path.join([workspace, "sub", "go.mod"]), "module x\n")

    detected = ContainerFeatures.detect(workspace)
    assert "make" in detected
    assert "go" in detected
  end

  test "detect recognizes docker via compose and devcontainer files", %{workspace: workspace} do
    File.write!(Path.join(workspace, "compose.yaml"), "services: {}\n")
    assert "docker" in ContainerFeatures.detect(workspace)

    File.rm!(Path.join(workspace, "compose.yaml"))
    File.mkdir_p!(Path.join(workspace, ".devcontainer"))
    File.write!(Path.join([workspace, ".devcontainer", "devcontainer.json"]), "{}")
    assert "docker" in ContainerFeatures.detect(workspace)
  end

  test "detect recognizes browser via config file", %{workspace: workspace} do
    File.write!(Path.join(workspace, "playwright.config.ts"), "export default {}\n")
    assert "browser" in ContainerFeatures.detect(workspace)
  end

  test "detect recognizes browser via package.json dependency hint", %{workspace: workspace} do
    File.write!(Path.join(workspace, "package.json"), ~s({"devDependencies":{"playwright":"1"}}))
    detected = ContainerFeatures.detect(workspace)
    assert "browser" in detected
    assert "node" in detected
  end

  test "detect tolerates an unreadable package.json", %{workspace: workspace} do
    # A directory named package.json makes File.read return an error, which the
    # browser dependency scan must treat as "no hint" rather than crashing.
    File.mkdir_p!(Path.join(workspace, "package.json"))
    refute "browser" in ContainerFeatures.detect(workspace)
  end

  test "resolve auto-detects, honors explicit ids, and warns on unknown ids", %{workspace: workspace} do
    File.write!(Path.join(workspace, "Makefile"), "all:\n")

    assert ["make"] = ContainerFeatures.resolve(["auto"], workspace) |> Enum.map(& &1.id)

    # Explicit ids (with blanks and casing normalized) plus auto-detected ones.
    log =
      capture_log(fn ->
        ids =
          ["AUTO", "", "browser", "made-up"]
          |> ContainerFeatures.resolve(workspace)
          |> Enum.map(& &1.id)
          |> Enum.sort()

        send(self(), {:ids, ids})
      end)

    assert_received {:ids, ["browser", "make"]}
    assert log =~ "Ignoring unknown container feature"

    # Explicit-only (no auto) selects exactly the requested known features.
    assert ["docker"] = ContainerFeatures.resolve(["docker"], workspace) |> Enum.map(& &1.id)
  end

  test "provision_script gates on a marker and an optional fast check" do
    catalog = ContainerFeatures.builtin_features()

    make_script = ContainerFeatures.provision_script(catalog["make"])
    assert make_script =~ "/var/lib/symphony/features/make"
    assert make_script =~ "command -v make"
    assert make_script =~ "apt-get install"

    browser_script = ContainerFeatures.provision_script(catalog["browser"])
    assert browser_script =~ "playwright install"
    # Browser has no fast check command, so the check line is omitted.
    refute browser_script =~ "if command -v"
  end

  test "provision classifies provisioned, skipped, and failed features" do
    catalog = ContainerFeatures.builtin_features()
    features = [catalog["make"], catalog["docker"], catalog["go"], catalog["rust"], catalog["python"]]
    long_output = String.duplicate("x", 5_000)

    runner = fn _name, script ->
      cond do
        script =~ "features/make" -> {:ok, {"installed make\n", 0}}
        script =~ "features/docker" -> {:ok, {"symphony-feature-already-satisfied\n", 0}}
        script =~ "features/go" -> {:ok, {long_output, 100}}
        script =~ "features/python" -> {:ok, {"short failure", 1}}
        script =~ "features/rust" -> {:error, :engine_unreachable}
      end
    end

    log =
      capture_log(fn ->
        result = ContainerFeatures.provision("symphony-agent-MT-1", features, runner)
        send(self(), {:result, result})
      end)

    assert_received {:result, result}
    assert result.provisioned == ["make"]
    assert result.skipped == ["docker"]
    assert Enum.sort(result.failed) == ["go", "python", "rust"]
    assert log =~ "Container feature install failed"
    assert log =~ "Container feature install errored"
    assert log =~ "(truncated)"
  end

  test "marker_root is exposed" do
    assert ContainerFeatures.marker_root() == "/var/lib/symphony/features"
  end
end

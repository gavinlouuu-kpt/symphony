defmodule SymphonyElixir.ContainerFeatures do
  @moduledoc """
  Reusable, devcontainer-style "features" that the setup phase of the container
  orchestrator installs into a per-issue desktop container.

  Each feature is a small, self-contained recipe describing:

    * how to *detect* whether the bind-mounted workspace needs it (file globs and
      `package.json`-style dependency hints), so the orchestrator can decide what
      to install instead of baking everything into the base image;
    * a fast *check* command that short-circuits provisioning when the tool is
      already present (the base image already ships Node, `git`, etc.); and
    * the *install* commands to run inside the container.

  Provisioning is idempotent: each feature drops a marker file under
  `#{inspect(:marker_root)}` once installed (or detected as already present), so
  reusing a container across turns and retries re-runs each recipe as a cheap
  no-op. This keeps features reusable both within a container's lifetime and as
  a shared catalog across every issue.
  """

  require Logger

  @marker_root "/var/lib/symphony/features"

  @type feature_id :: String.t()

  @type feature :: %{
          id: feature_id(),
          summary: String.t(),
          detect: (Path.t() -> boolean()),
          check: String.t() | nil,
          install: [String.t()]
        }

  @type provision_runner :: (String.t(), String.t() -> {:ok, {String.t(), integer()}} | {:error, term()})

  @type provision_result :: %{
          provisioned: [feature_id()],
          skipped: [feature_id()],
          failed: [feature_id()]
        }

  @doc """
  The built-in catalog of reusable features keyed by id.
  """
  @spec builtin_features() :: %{feature_id() => feature()}
  def builtin_features do
    %{
      "make" => %{
        id: "make",
        summary: "GNU make and a C toolchain (build-essential)",
        detect: &detect_make/1,
        check: "command -v make",
        install: apt_install(["build-essential", "make"])
      },
      "docker" => %{
        id: "docker",
        summary: "Docker CLI for building/running containers",
        detect: &detect_docker/1,
        check: "command -v docker",
        install: apt_install(["docker.io"])
      },
      "node" => %{
        id: "node",
        summary: "Node.js package managers via corepack",
        detect: &detect_node/1,
        check: "command -v corepack",
        install: ["corepack enable"]
      },
      "python" => %{
        id: "python",
        summary: "Python 3 with pip and venv",
        detect: &detect_python/1,
        check: "command -v python3 && command -v pip3",
        install: apt_install(["python3", "python3-pip", "python3-venv"])
      },
      "rust" => %{
        id: "rust",
        summary: "Rust toolchain (rustc + cargo)",
        detect: &detect_rust/1,
        check: "command -v cargo",
        install: apt_install(["rustc", "cargo"])
      },
      "go" => %{
        id: "go",
        summary: "Go toolchain",
        detect: &detect_go/1,
        check: "command -v go",
        install: apt_install(["golang-go"])
      },
      "browser" => %{
        id: "browser",
        summary: "Headless Chromium plus OS dependencies for browser testing",
        detect: &detect_browser/1,
        # No fast check: Playwright browsers live in a cache dir, so rely on the
        # idempotency marker to avoid re-downloading on every turn.
        check: nil,
        install: ["npx --yes playwright install --with-deps chromium"]
      }
    }
  end

  @doc """
  Resolves the feature specs to provision for `workspace`, honoring the
  configured `container.features` list.

  `["auto"]` (the default) auto-detects features from the workspace. An explicit
  list selects those features by id (unknown ids are ignored with a warning).
  `"auto"` may be combined with explicit ids to force extras on top of detection.
  """
  @spec resolve([String.t()], Path.t()) :: [feature()]
  def resolve(configured_features, workspace) when is_list(configured_features) do
    catalog = builtin_features()
    normalized = configured_features |> Enum.map(&normalize_id/1) |> Enum.reject(&(&1 == ""))

    auto? = "auto" in normalized
    explicit_ids = Enum.reject(normalized, &(&1 == "auto"))

    detected_ids = if auto?, do: detect(workspace), else: []

    selected_explicit =
      Enum.flat_map(explicit_ids, fn id ->
        case Map.get(catalog, id) do
          nil ->
            Logger.warning("Ignoring unknown container feature feature=#{inspect(id)}")
            []

          _feature ->
            [id]
        end
      end)

    (detected_ids ++ selected_explicit)
    |> Enum.uniq()
    |> Enum.map(&Map.fetch!(catalog, &1))
  end

  @doc """
  Returns the ids of built-in features whose detection rules match `workspace`.
  Returns `[]` for a missing or unreadable workspace.
  """
  @spec detect(Path.t()) :: [feature_id()]
  def detect(workspace) when is_binary(workspace) do
    if File.dir?(workspace) do
      builtin_features()
      |> Enum.filter(fn {_id, %{detect: detect}} -> detect.(workspace) end)
      |> Enum.map(fn {id, _feature} -> id end)
      |> Enum.sort()
    else
      []
    end
  end

  def detect(_workspace), do: []

  @doc """
  Provisions `features` inside `container_name` using `runner`, an
  `engine_exec/2`-style function. Provisioning is best-effort and idempotent:
  features that are already present (per the fast check) or previously installed
  (per the marker file) are skipped. Failures are logged and collected rather
  than raised, so a single bad recipe never aborts an agent run.
  """
  @spec provision(String.t(), [feature()], provision_runner()) :: provision_result()
  def provision(container_name, features, runner)
      when is_binary(container_name) and is_list(features) and is_function(runner, 2) do
    features
    |> Enum.reduce(%{provisioned: [], skipped: [], failed: []}, fn feature, acc ->
      record_feature(acc, container_name, feature, runner)
    end)
    |> Map.new(fn {bucket, ids} -> {bucket, Enum.reverse(ids)} end)
  end

  defp record_feature(acc, container_name, feature, runner) do
    case runner.(container_name, provision_script(feature)) do
      {:ok, {output, 0}} ->
        bucket = success_bucket(output)
        Logger.info("Provisioned container feature feature=#{feature.id} container_name=#{container_name} result=#{bucket}")
        Map.update!(acc, bucket, &[feature.id | &1])

      {:ok, {output, status}} ->
        Logger.warning("Container feature install failed feature=#{feature.id} container_name=#{container_name} status=#{status} output=#{inspect(truncate(output))}")
        Map.update!(acc, :failed, &[feature.id | &1])

      {:error, reason} ->
        Logger.warning("Container feature install errored feature=#{feature.id} container_name=#{container_name} error=#{inspect(reason)}")
        Map.update!(acc, :failed, &[feature.id | &1])
    end
  end

  defp success_bucket(output) do
    if already_satisfied_output?(output), do: :skipped, else: :provisioned
  end

  @doc """
  The shell script run inside the container for a single feature. Exposed for
  testing and debugging.
  """
  @spec provision_script(feature()) :: String.t()
  def provision_script(%{id: id, check: check, install: install}) do
    marker = Path.join(@marker_root, id)
    install_block = Enum.map_join(install, "\n", &("  " <> &1))

    [
      "set -e",
      "export DEBIAN_FRONTEND=noninteractive",
      "mkdir -p #{shell_escape(@marker_root)}",
      "if [ -f #{shell_escape(marker)} ]; then echo #{shell_escape(satisfied_token())}; exit 0; fi",
      check && "if #{check} >/dev/null 2>&1; then touch #{shell_escape(marker)}; echo #{shell_escape(satisfied_token())}; exit 0; fi",
      "(",
      install_block,
      ")",
      "touch #{shell_escape(marker)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  @spec marker_root() :: String.t()
  def marker_root, do: @marker_root

  # Detection rules ----------------------------------------------------------

  defp detect_make(workspace) do
    any_glob?(workspace, ["Makefile", "makefile", "GNUmakefile", "*/Makefile", "*/makefile", "*/GNUmakefile"])
  end

  defp detect_docker(workspace) do
    any_glob?(workspace, [
      "Dockerfile",
      "*/Dockerfile",
      "docker-compose.yml",
      "docker-compose.yaml",
      "compose.yml",
      "compose.yaml",
      ".devcontainer/devcontainer.json"
    ])
  end

  defp detect_node(workspace) do
    any_glob?(workspace, ["package.json", "*/package.json"])
  end

  defp detect_python(workspace) do
    any_glob?(workspace, [
      "requirements.txt",
      "*/requirements.txt",
      "pyproject.toml",
      "*/pyproject.toml",
      "setup.py",
      "Pipfile"
    ])
  end

  defp detect_rust(workspace) do
    any_glob?(workspace, ["Cargo.toml", "*/Cargo.toml"])
  end

  defp detect_go(workspace) do
    any_glob?(workspace, ["go.mod", "*/go.mod"])
  end

  defp detect_browser(workspace) do
    any_glob?(workspace, [
      "playwright.config.js",
      "playwright.config.ts",
      "*/playwright.config.js",
      "*/playwright.config.ts",
      "cypress.config.js",
      "cypress.config.ts"
    ]) or package_json_mentions_browser?(workspace)
  end

  defp package_json_mentions_browser?(workspace) do
    workspace
    |> package_json_paths()
    |> Enum.any?(fn path ->
      case File.read(path) do
        {:ok, contents} ->
          String.contains?(contents, ["playwright", "puppeteer", "cypress"])

        _ ->
          false
      end
    end)
  end

  defp package_json_paths(workspace) do
    glob(workspace, "package.json") ++ glob(workspace, "*/package.json")
  end

  defp any_glob?(workspace, patterns) do
    Enum.any?(patterns, fn pattern -> glob(workspace, pattern) != [] end)
  end

  defp glob(workspace, pattern) do
    Path.wildcard(Path.join(workspace, pattern), match_dot: true)
  end

  # Helpers ------------------------------------------------------------------

  defp apt_install(packages) do
    [
      "apt-get update",
      "apt-get install -y --no-install-recommends " <> Enum.join(packages, " ")
    ]
  end

  defp normalize_id(value) do
    value |> to_string() |> String.trim() |> String.downcase()
  end

  defp satisfied_token, do: "symphony-feature-already-satisfied"

  defp already_satisfied_output?(output) do
    String.contains?(to_string(output), satisfied_token())
  end

  defp truncate(output, max_bytes \\ 2_048) do
    binary = IO.iodata_to_binary(output)

    if byte_size(binary) <= max_bytes do
      binary
    else
      binary_part(binary, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end

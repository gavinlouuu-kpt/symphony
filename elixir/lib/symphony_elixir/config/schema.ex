defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety

  @primary_key false

  @linear_default_endpoint "https://api.linear.app/graphql"
  @github_default_endpoint "https://api.github.com"

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      field(:required_labels, {:array, :string}, default: [])
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:kind, :endpoint, :api_key, :project_slug, :assignee, :required_labels, :active_states, :terminal_states],
        empty_values: []
      )
      |> update_change(:required_labels, fn labels ->
        labels
        |> Enum.map(&(String.trim(&1) |> String.downcase()))
        |> Enum.uniq()
      end)
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:provider, :string, default: "ssh")
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:ssh_options, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:provider, :ssh_hosts, :ssh_options, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Cua do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:driver, :string, default: "docker")
      field(:executable, :string, default: "docker")
      field(:host, :string, default: "127.0.0.1")
      field(:image, :string, default: "symphony-cua-worker:latest")
      field(:name_prefix, :string, default: "symphony")
      field(:ssh_user, :string, default: "cua")
      field(:ssh_authorized_key_path, :string, default: "~/.ssh/id_ed25519.pub")
      field(:codex_auth_path, :string)
      field(:codex_config_path, :string)
      field(:delete_on_terminal, :boolean, default: false)
      field(:wait_for_ssh, :boolean, default: true)
      field(:launch_timeout_ms, :integer, default: 120_000)
      field(:port_span, :integer, default: 1_000)
      field(:ssh_port_start, :integer, default: 22_000)
      field(:vnc_port_start, :integer, default: 15_900)
      field(:novnc_port_start, :integer, default: 16_900)
      field(:api_port_start, :integer, default: 18_000)
      field(:env, :map, default: %{})
      field(:volumes, {:array, :string}, default: [])
      field(:docker_args, {:array, :string}, default: [])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :driver,
          :executable,
          :host,
          :image,
          :name_prefix,
          :ssh_user,
          :ssh_authorized_key_path,
          :codex_auth_path,
          :codex_config_path,
          :delete_on_terminal,
          :wait_for_ssh,
          :launch_timeout_ms,
          :port_span,
          :ssh_port_start,
          :vnc_port_start,
          :novnc_port_start,
          :api_port_start,
          :env,
          :volumes,
          :docker_args
        ],
        empty_values: []
      )
      |> validate_required([:driver, :executable, :host, :image, :name_prefix, :ssh_user])
      |> validate_number(:launch_timeout_ms, greater_than: 0)
      |> validate_number(:port_span, greater_than: 0, less_than_or_equal_to: 10_000)
      |> validate_port(:ssh_port_start)
      |> validate_port(:vnc_port_start)
      |> validate_port(:novnc_port_start)
      |> validate_port(:api_port_start)
    end

    defp validate_port(changeset, field) do
      validate_number(changeset, field, greater_than: 0, less_than_or_equal_to: 65_535)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
      field(:role_agents, {:array, :string}, default: [])
      field(:unroute_grace_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :max_concurrent_agents,
          :max_turns,
          :max_retry_backoff_ms,
          :max_concurrent_agents_by_state,
          :role_agents,
          :unroute_grace_ms
        ],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> validate_number(:unroute_grace_ms, greater_than_or_equal_to: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
      |> update_change(:role_agents, &Schema.normalize_string_list/1)
      |> validate_length(:role_agents, max: 12)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule SandboxContract do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enforced, :boolean, default: false)
      field(:audited, :boolean, default: false)
      field(:required_commands, {:array, :string}, default: [])
      field(:required_python_modules, {:array, :string}, default: [])
      field(:required_system_packages, {:array, :string}, default: [])
      field(:bootstrap_check, :string)
      field(:notes, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :enforced,
          :audited,
          :required_commands,
          :required_python_modules,
          :required_system_packages,
          :bootstrap_check,
          :notes
        ],
        empty_values: []
      )
      |> update_change(:required_commands, &normalize_string_list/1)
      |> update_change(:required_python_modules, &normalize_string_list/1)
      |> update_change(:required_system_packages, &normalize_string_list/1)
      |> validate_enforced_contract()
    end

    defp normalize_string_list(values) when is_list(values) do
      values
      |> Enum.map(&(to_string(&1) |> String.trim()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end

    defp normalize_string_list(value) when is_binary(value) do
      value
      |> String.split(",")
      |> normalize_string_list()
    end

    defp normalize_string_list(_value), do: []

    defp validate_enforced_contract(changeset) do
      case get_field(changeset, :enforced) do
        true ->
          changeset
          |> require_audited()
          |> validate_required([:bootstrap_check])
          |> validate_non_empty_bootstrap_check()
          |> require_any_requirement()

        _ ->
          changeset
      end
    end

    defp require_audited(changeset) do
      case get_field(changeset, :audited) do
        true -> changeset
        _ -> add_error(changeset, :audited, "must be true when sandbox contract is enforced")
      end
    end

    defp validate_non_empty_bootstrap_check(changeset) do
      validate_change(changeset, :bootstrap_check, fn :bootstrap_check, value ->
        if is_binary(value) and String.trim(value) == "" do
          [bootstrap_check: "can't be blank"]
        else
          []
        end
      end)
    end

    defp require_any_requirement(changeset) do
      has_requirement? =
        Enum.any?(
          [
            get_field(changeset, :required_commands, []),
            get_field(changeset, :required_python_modules, []),
            get_field(changeset, :required_system_packages, [])
          ],
          &(&1 != [])
        ) ||
          present?(get_field(changeset, :notes))

      case has_requirement? do
        true ->
          changeset

        false ->
          add_error(
            changeset,
            :required_commands,
            "must declare at least one sandbox requirement or note when contract is enforced"
          )
      end
    end

    defp present?(value) when is_binary(value), do: String.trim(value) != ""
    defp present?(_value), do: false
  end

  defmodule EvidenceContract do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:enforced, :boolean, default: false)
      field(:audited, :boolean, default: false)
      field(:required_checks, {:array, :string}, default: [])
      field(:required_artifacts, {:array, :string}, default: [])
      field(:required_commands, {:array, :string}, default: [])
      field(:notes, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :enforced,
          :audited,
          :required_checks,
          :required_artifacts,
          :required_commands,
          :notes
        ],
        empty_values: []
      )
      |> update_change(:required_checks, &Schema.normalize_string_list/1)
      |> update_change(:required_artifacts, &Schema.normalize_string_list/1)
      |> update_change(:required_commands, &Schema.normalize_string_list/1)
      |> validate_enforced_contract()
    end

    defp validate_enforced_contract(changeset) do
      case get_field(changeset, :enforced) do
        true ->
          changeset
          |> require_audited()
          |> require_any_requirement()

        _ ->
          changeset
      end
    end

    defp require_audited(changeset) do
      case get_field(changeset, :audited) do
        true -> changeset
        _ -> add_error(changeset, :audited, "must be true when evidence contract is enforced")
      end
    end

    defp require_any_requirement(changeset) do
      has_requirement? =
        Enum.any?(
          [
            get_field(changeset, :required_checks, []),
            get_field(changeset, :required_artifacts, []),
            get_field(changeset, :required_commands, [])
          ],
          &(&1 != [])
        ) ||
          present?(get_field(changeset, :notes))

      case has_requirement? do
        true ->
          changeset

        false ->
          add_error(
            changeset,
            :required_checks,
            "must declare at least one evidence requirement or note when contract is enforced"
          )
      end
    end

    defp present?(value) when is_binary(value), do: String.trim(value) != ""
    defp present?(_value), do: false
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule OpenClaw do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:command, :string, default: "openclaw")
      field(:channel, :string, default: "discord")
      field(:account, :string)
      field(:target, :string)
      field(:timeout_ms, :integer, default: 10_000)
      field(:intake_enabled, :boolean, default: false)
      field(:intake_token, :string)
      field(:intake_labels, {:array, :string}, default: [])

      field(:events, {:array, :string},
        default: [
          "dispatch_started",
          "role_agent_completed",
          "agent_completed",
          "issue_blocked",
          "retry_scheduled"
        ]
      )
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :enabled,
          :command,
          :channel,
          :account,
          :target,
          :timeout_ms,
          :intake_enabled,
          :intake_token,
          :intake_labels,
          :events
        ],
        empty_values: []
      )
      |> validate_number(:timeout_ms, greater_than: 0)
      |> update_change(:intake_labels, &normalize_label_list/1)
      |> update_change(:events, fn events ->
        events
        |> Enum.map(&(String.trim(&1) |> String.downcase()))
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
      end)
    end

    defp normalize_label_list(labels) do
      labels
      |> Enum.map(&(String.trim(&1) |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:cua, Cua, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:sandbox_contract, SandboxContract, on_replace: :update, defaults_to_struct: true)
    embeds_one(:evidence_contract, EvidenceContract, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:openclaw, OpenClaw, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec normalize_string_list(nil | [term()] | term()) :: [String.t()]
  def normalize_string_list(nil), do: []

  def normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&(to_string(&1) |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize_string_list(value) do
    value
    |> to_string()
    |> String.split(",")
    |> normalize_string_list()
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:cua, with: &Cua.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:sandbox_contract, with: &SandboxContract.changeset/2)
    |> cast_embed(:evidence_contract, with: &EvidenceContract.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:openclaw, with: &OpenClaw.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
  end

  defp finalize_settings(settings) do
    tracker_kind = settings.tracker.kind

    tracker = %{
      settings.tracker
      | endpoint: resolve_tracker_endpoint(tracker_kind, settings.tracker.endpoint),
        api_key: resolve_secret_setting(settings.tracker.api_key, tracker_api_key_fallback(tracker_kind)),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    cua = %{
      settings.cua
      | env: normalize_keys(settings.cua.env),
        ssh_authorized_key_path: resolve_optional_path_value(settings.cua.ssh_authorized_key_path),
        codex_auth_path: resolve_optional_path_value(settings.cua.codex_auth_path),
        codex_config_path: resolve_optional_path_value(settings.cua.codex_config_path)
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    openclaw = %{
      settings.openclaw
      | command: resolve_optional_env_setting(settings.openclaw.command),
        channel: resolve_optional_env_setting(settings.openclaw.channel),
        account: resolve_optional_env_setting(settings.openclaw.account),
        target: resolve_optional_env_setting(settings.openclaw.target),
        intake_token:
          resolve_secret_setting(
            settings.openclaw.intake_token,
            System.get_env("SYMPHONY_OPENCLAW_INTAKE_TOKEN")
          )
    }

    %{settings | tracker: tracker, workspace: workspace, cua: cua, codex: codex, openclaw: openclaw}
  end

  defp resolve_tracker_endpoint("github", endpoint)
       when endpoint in [nil, "", @linear_default_endpoint],
       do: @github_default_endpoint

  defp resolve_tracker_endpoint(_kind, endpoint), do: endpoint

  defp tracker_api_key_fallback("github"),
    do: System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")

  defp tracker_api_key_fallback(_kind), do: System.get_env("LINEAR_API_KEY")

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_optional_env_setting(nil), do: nil

  defp resolve_optional_env_setting(value) when is_binary(value) do
    case resolve_env_value(value, nil) do
      resolved when is_binary(resolved) -> normalize_blank_string(resolved)
      _ -> nil
    end
  end

  defp resolve_optional_env_setting(_value), do: nil

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_optional_path_value(nil), do: nil
  defp resolve_optional_path_value(""), do: nil

  defp resolve_optional_path_value(value) when is_binary(value) do
    case resolve_path_value(value, nil) do
      path when is_binary(path) -> Path.expand(path)
      other -> other
    end
  end

  defp resolve_optional_path_value(_value), do: nil

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp normalize_blank_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end

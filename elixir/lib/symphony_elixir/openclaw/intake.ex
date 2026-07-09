defmodule SymphonyElixir.OpenClaw.Intake do
  @moduledoc """
  Creates GitHub tracker issues from OpenClaw channel messages.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Github.Client, as: GithubClient
  alias SymphonyElixir.Linear.Issue

  @issue_prefix ~r/^\s*(?:\/?issue|gh\s+issue|github\s+issue|open\s+issue)\b[:\-\s]*/i
  @max_title_length 250

  @spec create_issue(map()) :: {:ok, map()} | {:error, term()}
  def create_issue(payload) when is_map(payload) do
    settings = Config.settings!()

    with :ok <- intake_enabled?(settings),
         :ok <- github_tracker?(settings),
         {:ok, title, body, labels} <- normalize_issue_payload(payload, settings),
         {:ok, %Issue{} = issue} <- github_client_module().create_issue(title, body, labels) do
      {:ok,
       %{
         issue: issue,
         message: "Created GitHub issue #{issue.identifier}: #{issue.title}\n#{issue.url}"
       }}
    end
  end

  def create_issue(_payload), do: {:error, :invalid_openclaw_intake_payload}

  defp intake_enabled?(settings) do
    if settings.openclaw.intake_enabled == true do
      :ok
    else
      {:error, :openclaw_intake_disabled}
    end
  end

  defp github_tracker?(settings) do
    if settings.tracker.kind == "github" do
      :ok
    else
      {:error, :openclaw_intake_requires_github_tracker}
    end
  end

  defp normalize_issue_payload(payload, settings) do
    text = payload_text(payload)

    with {:ok, title} <- issue_title(payload, text),
         body <- issue_body(payload, text, title),
         labels <- issue_labels(payload, settings) do
      {:ok, title, body, labels}
    end
  end

  defp payload_text(payload) do
    payload
    |> pick_string(["text", "content", "message"])
    |> String.trim()
  end

  defp issue_title(payload, text) do
    explicit_title = pick_string(payload, ["title"])

    title =
      if explicit_title == "" do
        text
        |> String.replace(@issue_prefix, "")
        |> first_non_empty_line()
      else
        explicit_title
      end

    case normalize_title(title) do
      "" -> {:error, :missing_issue_title}
      normalized -> {:ok, normalized}
    end
  end

  defp issue_body(payload, text, title) do
    explicit_body = pick_string(payload, ["body", "description"])

    body =
      cond do
        explicit_body != "" ->
          explicit_body

        text != "" ->
          text_to_body(text, title)

        true ->
          "Created from OpenClaw intake."
      end

    body
    |> append_orchestration_block()
    |> append_source_block(payload)
    |> String.trim()
  end

  defp text_to_body(text, title) do
    stripped = String.replace(text, @issue_prefix, "")

    stripped
    |> String.split("\n", trim: false)
    |> drop_title_line(title)
    |> Enum.join("\n")
    |> String.trim()
    |> case do
      "" -> stripped
      body -> body
    end
  end

  defp drop_title_line([], _title), do: []

  defp drop_title_line([line | rest], title) do
    if normalize_title(line) == title do
      rest
    else
      [line | rest]
    end
  end

  defp append_source_block(body, payload) do
    source = source_metadata(payload)

    if source == [] do
      body
    else
      body <> "\n\n---\nOpenClaw intake:\n" <> Enum.map_join(source, "\n", fn {key, value} -> "- #{key}: #{value}" end)
    end
  end

  defp append_orchestration_block(body) do
    if String.contains?(body, "## OpenClaw Orchestration") do
      body
    else
      body <>
        """


        ## OpenClaw Orchestration

        This issue is routed through independent Planner -> Generator -> Evaluator agents.

        Required phase evidence:

        - Planner: read the current project `AGENTS.md` and relevant docs, clarify scope, acceptance criteria, risk tier, and validation before code changes.
        - Generator: implement only against the accepted plan, keep changes scoped, and record changed files plus validation commands.
        - Evaluator: independently review the result against the plan, acceptance criteria, tests, and project guardrails before handoff.

        The Symphony runner must start separate role-agent sessions for Planner, Generator, and Evaluator. A single agent writing three sections does not satisfy this contract. The Symphony workpad must include all three independent agent outcomes before the issue is marked ready for review or complete.

        Keep the project bookkeeping label separate from the active routing label. The active routing label, usually `openclaw-intake`, keeps the issue in Symphony's queue. Remove only that active routing label when the PR is ready for human review, blocked on external input, or complete. Leave the GitHub issue open for normal review handoff and close it only after the repository's merge/completion expectations are satisfied.

        Discord/OpenClaw status belongs in the issue thread: dispatch starts the thread, and role-agent, completion, blocked, and retry updates should continue there.
        """
    end
  end

  defp source_metadata(payload) do
    source = Map.get(payload, "source") || Map.get(payload, :source) || %{}

    [
      {"channel", source_value(source, "channel")},
      {"channel_id", source_value(source, "channel_id")},
      {"message_id", source_value(source, "message_id")},
      {"sender", source_value(source, "sender")}
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp source_value(source, key) when is_map(source) do
    value = Map.get(source, key) || Map.get(source, String.to_atom(key))
    if is_binary(value), do: String.trim(value), else: value
  end

  defp source_value(_source, _key), do: nil

  defp issue_labels(payload, settings) do
    payload_labels = list_value(payload, ["labels"])

    (settings.tracker.required_labels ++ settings.openclaw.intake_labels ++ payload_labels)
    |> Enum.map(&normalize_label/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp list_value(payload, keys) do
    keys
    |> Enum.find_value([], fn key ->
      case Map.get(payload, key) || Map.get(payload, String.to_atom(key)) do
        values when is_list(values) -> values
        value when is_binary(value) -> String.split(value, ",")
        _ -> nil
      end
    end)
  end

  defp pick_string(payload, keys) do
    keys
    |> Enum.find_value("", fn key ->
      value = Map.get(payload, key) || Map.get(payload, String.to_atom(key))
      if is_binary(value), do: String.trim(value), else: nil
    end)
  end

  defp first_non_empty_line(text) do
    text
    |> String.split("\n")
    |> Enum.find("", &(String.trim(&1) != ""))
  end

  defp normalize_title(title) when is_binary(title) do
    title
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, @max_title_length)
  end

  defp normalize_title(_title), do: ""

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_label(label), do: label |> to_string() |> normalize_label()

  defp github_client_module do
    Application.get_env(:symphony_elixir, :github_client_module, GithubClient)
  end
end

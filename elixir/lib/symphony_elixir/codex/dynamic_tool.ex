defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Linear.Client, SSH}

  @linear_graphql_tool "linear_graphql"
  @sandbox_exec_tool "sandbox_exec"
  @sandbox_visible_exec_tool "sandbox_visible_exec"
  @sandbox_read_file_tool "sandbox_read_file"
  @sandbox_write_file_tool "sandbox_write_file"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @sandbox_exec_description """
  Execute a shell command inside the issue's CUA sandbox workspace. Use this for all shell work when Symphony says the agent is controlling a sandbox from the host.
  """
  @sandbox_visible_exec_description """
  Execute a shell command inside a visible terminal on the CUA desktop. Use this for real-user validation, demos, browser/app startup, and any task step that should be observable through noVNC.
  """
  @sandbox_read_file_description """
  Read a UTF-8 text file from the issue's CUA sandbox workspace.
  """
  @sandbox_write_file_description """
  Write a UTF-8 text file into the issue's CUA sandbox workspace, creating parent directories when needed.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @sandbox_exec_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["command"],
    "properties" => %{
      "command" => %{
        "type" => "string",
        "description" => "Shell command to run from the sandbox workspace."
      }
    }
  }
  @sandbox_visible_exec_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["command"],
    "properties" => %{
      "command" => %{
        "type" => "string",
        "description" => "Shell command to run from the sandbox workspace in a visible desktop terminal."
      },
      "title" => %{
        "type" => ["string", "null"],
        "description" => "Optional terminal window title."
      },
      "timeout_ms" => %{
        "type" => ["integer", "null"],
        "minimum" => 1,
        "description" => "Optional maximum time to wait for the command before returning. The visible terminal remains open if the command is still running."
      }
    }
  }
  @sandbox_read_file_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["path"],
    "properties" => %{
      "path" => %{
        "type" => "string",
        "description" => "Relative path under the sandbox workspace."
      }
    }
  }
  @sandbox_write_file_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["path", "content"],
    "properties" => %{
      "path" => %{
        "type" => "string",
        "description" => "Relative path under the sandbox workspace."
      },
      "content" => %{
        "type" => "string",
        "description" => "Text content to write."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @sandbox_exec_tool ->
        execute_sandbox_exec(arguments, opts)

      @sandbox_visible_exec_tool ->
        execute_sandbox_visible_exec(arguments, opts)

      @sandbox_read_file_tool ->
        execute_sandbox_read_file(arguments, opts)

      @sandbox_write_file_tool ->
        execute_sandbox_write_file(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names(opts)
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs(opts \\ []) do
    base_specs = [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]

    if sandbox_context?(Keyword.get(opts, :sandbox_context)) do
      base_specs ++
        [
          %{
            "name" => @sandbox_exec_tool,
            "description" => @sandbox_exec_description,
            "inputSchema" => @sandbox_exec_input_schema
          },
          %{
            "name" => @sandbox_visible_exec_tool,
            "description" => @sandbox_visible_exec_description,
            "inputSchema" => @sandbox_visible_exec_input_schema
          },
          %{
            "name" => @sandbox_read_file_tool,
            "description" => @sandbox_read_file_description,
            "inputSchema" => @sandbox_read_file_input_schema
          },
          %{
            "name" => @sandbox_write_file_tool,
            "description" => @sandbox_write_file_description,
            "inputSchema" => @sandbox_write_file_input_schema
          }
        ]
    else
      base_specs
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_sandbox_exec(arguments, opts) do
    with {:ok, sandbox} <- sandbox_context(opts),
         {:ok, command} <- normalize_command(arguments),
         {:ok, {output, status}} <-
           SSH.run(
             sandbox.worker_host,
             "cd #{shell_escape(sandbox.workspace)} && #{command}",
             stderr_to_stdout: true
           ) do
      dynamic_tool_response(
        status == 0,
        encode_payload(%{
          "status" => status,
          "output" => output
        })
      )
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_sandbox_visible_exec(arguments, opts) do
    with {:ok, sandbox} <- sandbox_context(opts),
         {:ok, command} <- normalize_command(arguments),
         {:ok, title} <- normalize_visible_title(arguments),
         {:ok, timeout_ms} <- normalize_visible_timeout_ms(arguments),
         {:ok, {output, status}} <-
           SSH.run(
             sandbox.worker_host,
             visible_exec_script(sandbox.workspace, command, title, timeout_ms),
             stderr_to_stdout: true
           ) do
      dynamic_tool_response(
        status == 0,
        encode_payload(%{
          "status" => status,
          "output" => output
        })
      )
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_sandbox_read_file(arguments, opts) do
    with {:ok, sandbox} <- sandbox_context(opts),
         {:ok, path} <- normalize_relative_path(arguments),
         {:ok, {output, 0}} <-
           SSH.run(
             sandbox.worker_host,
             sandbox_file_script(sandbox.workspace, path, "cat -- \"$target\""),
             stderr_to_stdout: true
           ) do
      dynamic_tool_response(true, output)
    else
      {:ok, {output, status}} ->
        failure_response(%{
          "error" => %{
            "message" => "Failed to read sandbox file.",
            "status" => status,
            "output" => output
          }
        })

      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_sandbox_write_file(arguments, opts) do
    with {:ok, sandbox} <- sandbox_context(opts),
         {:ok, path, content} <- normalize_write_file_arguments(arguments),
         encoded_content <- Base.encode64(content),
         {:ok, {output, 0}} <-
           SSH.run(
             sandbox.worker_host,
             sandbox_file_script(
               sandbox.workspace,
               path,
               "mkdir -p -- \"$(dirname -- \"$target\")\" && printf %s #{shell_escape(encoded_content)} | base64 -d > \"$target\""
             ),
             stderr_to_stdout: true
           ) do
      dynamic_tool_response(true, encode_payload(%{"status" => 0, "output" => output}))
    else
      {:ok, {output, status}} ->
        failure_response(%{
          "error" => %{
            "message" => "Failed to write sandbox file.",
            "status" => status,
            "output" => output
          }
        })

      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_command(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_command}
      command -> {:ok, command}
    end
  end

  defp normalize_command(arguments) when is_map(arguments) do
    case Map.get(arguments, "command") || Map.get(arguments, :command) do
      command when is_binary(command) ->
        normalize_command(command)

      _ ->
        {:error, :missing_command}
    end
  end

  defp normalize_command(_arguments), do: {:error, :invalid_arguments}

  defp normalize_visible_title(arguments) when is_map(arguments) do
    case Map.get(arguments, "title") || Map.get(arguments, :title) do
      title when is_binary(title) ->
        case String.trim(title) do
          "" -> {:ok, "Symphony visible exec"}
          trimmed -> {:ok, trimmed}
        end

      nil ->
        {:ok, "Symphony visible exec"}

      _ ->
        {:error, :invalid_visible_title}
    end
  end

  defp normalize_visible_title(_arguments), do: {:ok, "Symphony visible exec"}

  defp normalize_visible_timeout_ms(arguments) when is_map(arguments) do
    case Map.get(arguments, "timeout_ms") || Map.get(arguments, :timeout_ms) do
      nil -> {:ok, 600_000}
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> {:ok, timeout_ms}
      _ -> {:error, :invalid_visible_timeout}
    end
  end

  defp normalize_visible_timeout_ms(_arguments), do: {:ok, 600_000}

  defp normalize_relative_path(arguments) when is_map(arguments) do
    case Map.get(arguments, "path") || Map.get(arguments, :path) do
      path when is_binary(path) ->
        validate_relative_path(path)

      _ ->
        {:error, :missing_path}
    end
  end

  defp normalize_relative_path(path) when is_binary(path), do: validate_relative_path(path)
  defp normalize_relative_path(_arguments), do: {:error, :invalid_arguments}

  defp normalize_write_file_arguments(arguments) when is_map(arguments) do
    with {:ok, path} <- normalize_relative_path(arguments) do
      case Map.get(arguments, "content") || Map.get(arguments, :content) do
        content when is_binary(content) -> {:ok, path, content}
        _ -> {:error, :missing_content}
      end
    end
  end

  defp normalize_write_file_arguments(_arguments), do: {:error, :invalid_arguments}

  defp validate_relative_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" ->
        {:error, :missing_path}

      Path.type(trimmed) == :absolute ->
        {:error, :absolute_sandbox_path}

      String.contains?(trimmed, ["\n", "\r", <<0>>]) ->
        {:error, :invalid_sandbox_path}

      true ->
        {:ok, trimmed}
    end
  end

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_command) do
    %{
      "error" => %{
        "message" => "`sandbox_exec.command` must be a non-empty shell command."
      }
    }
  end

  defp tool_error_payload(:invalid_visible_title) do
    %{
      "error" => %{
        "message" => "`sandbox_visible_exec.title` must be a string when provided."
      }
    }
  end

  defp tool_error_payload(:invalid_visible_timeout) do
    %{
      "error" => %{
        "message" => "`sandbox_visible_exec.timeout_ms` must be a positive integer when provided."
      }
    }
  end

  defp tool_error_payload(:missing_path) do
    %{
      "error" => %{
        "message" => "Sandbox file tools require a non-empty relative `path`."
      }
    }
  end

  defp tool_error_payload(:missing_content) do
    %{
      "error" => %{
        "message" => "`sandbox_write_file.content` must be a string."
      }
    }
  end

  defp tool_error_payload(:absolute_sandbox_path) do
    %{
      "error" => %{
        "message" => "Sandbox file paths must be relative to the sandbox workspace."
      }
    }
  end

  defp tool_error_payload(:invalid_sandbox_path) do
    %{
      "error" => %{
        "message" => "Sandbox file path contains invalid characters."
      }
    }
  end

  defp tool_error_payload(:missing_sandbox_context) do
    %{
      "error" => %{
        "message" => "Sandbox tools are unavailable because this Codex session is not attached to a sandbox."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp sandbox_context(opts) do
    opts
    |> Keyword.get(:sandbox_context)
    |> normalize_sandbox_context()
  end

  defp normalize_sandbox_context(%{worker_host: worker_host, workspace: workspace})
       when is_binary(worker_host) and is_binary(workspace) do
    {:ok, %{worker_host: worker_host, workspace: workspace}}
  end

  defp normalize_sandbox_context(%{"worker_host" => worker_host, "workspace" => workspace})
       when is_binary(worker_host) and is_binary(workspace) do
    {:ok, %{worker_host: worker_host, workspace: workspace}}
  end

  defp normalize_sandbox_context(_context), do: {:error, :missing_sandbox_context}

  defp sandbox_context?(context) do
    match?({:ok, _}, normalize_sandbox_context(context))
  end

  defp sandbox_file_script(workspace, path, action) do
    [
      "workspace=#{shell_escape(workspace)}",
      "path=#{shell_escape(path)}",
      "target=$(realpath -m -- \"$workspace/$path\")",
      "case \"$target/\" in \"$workspace\"/*) ;; *) echo sandbox path escapes workspace >&2; exit 64 ;; esac",
      action
    ]
    |> Enum.join("\n")
  end

  defp visible_exec_script(workspace, command, title, timeout_ms) do
    command_b64 = Base.encode64(command)
    title_b64 = Base.encode64(title)
    timeout_seconds = max(1, div(timeout_ms + 999, 1_000))

    """
    set -eu
    workspace=#{shell_escape(workspace)}
    run_dir="$workspace/.symphony/visible-exec"
    mkdir -p -- "$run_dir"
    run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    command="$(printf %s #{shell_escape(command_b64)} | base64 -d)"
    title="$(printf %s #{shell_escape(title_b64)} | base64 -d)"
    log="$run_dir/$run_id.log"
    status_file="$run_dir/$run_id.status"
    runner="$run_dir/$run_id.sh"
    launcher="$run_dir/$run_id.launcher.sh"

    if command -v xfce4-terminal >/dev/null 2>&1 ||
       command -v x-terminal-emulator >/dev/null 2>&1 ||
       command -v xterm >/dev/null 2>&1; then
      :
    else
      echo "No terminal emulator found in CUA desktop image" >&2
      exit 127
    fi

    cat > "$runner" <<'SYMPHONY_VISIBLE_RUNNER'
    #!/usr/bin/env bash
    set +e
    cd "$SYMPHONY_VISIBLE_WORKSPACE" || exit 111
    {
      printf 'Symphony visible exec\\n'
      printf 'workspace: %s\\n' "$SYMPHONY_VISIBLE_WORKSPACE"
      printf 'started: %s\\n' "$(date -Iseconds)"
      printf 'command: %s\\n\\n' "$SYMPHONY_VISIBLE_COMMAND"
    } | tee "$SYMPHONY_VISIBLE_LOG"
    bash -lc "$SYMPHONY_VISIBLE_COMMAND" 2>&1 | tee -a "$SYMPHONY_VISIBLE_LOG"
    status=${PIPESTATUS[0]}
    {
      printf '\\nexit status: %s\\n' "$status"
      printf 'finished: %s\\n' "$(date -Iseconds)"
      printf '\\nWindow held for noVNC review. Close it manually when done.\\n'
    } | tee -a "$SYMPHONY_VISIBLE_LOG"
    printf '%s' "$status" > "$SYMPHONY_VISIBLE_STATUS_FILE"
    tail -f /dev/null
    SYMPHONY_VISIBLE_RUNNER

    cat > "$launcher" <<'SYMPHONY_VISIBLE_LAUNCHER'
    #!/usr/bin/env bash
    set -eu
    if command -v xfce4-terminal >/dev/null 2>&1; then
      exec xfce4-terminal --title "$SYMPHONY_VISIBLE_TITLE" --command "bash '$SYMPHONY_VISIBLE_RUNNER'"
    elif command -v x-terminal-emulator >/dev/null 2>&1; then
      exec x-terminal-emulator -T "$SYMPHONY_VISIBLE_TITLE" -e bash "$SYMPHONY_VISIBLE_RUNNER"
    elif command -v xterm >/dev/null 2>&1; then
      exec xterm -T "$SYMPHONY_VISIBLE_TITLE" -e bash "$SYMPHONY_VISIBLE_RUNNER"
    else
      echo "No terminal emulator found in CUA desktop image" >&2
      exit 127
    fi
    SYMPHONY_VISIBLE_LAUNCHER

    chmod +x "$runner" "$launcher"
    env DISPLAY="${DISPLAY:-:1}" \
      SYMPHONY_VISIBLE_WORKSPACE="$workspace" \
      SYMPHONY_VISIBLE_COMMAND="$command" \
      SYMPHONY_VISIBLE_TITLE="$title" \
      SYMPHONY_VISIBLE_LOG="$log" \
      SYMPHONY_VISIBLE_STATUS_FILE="$status_file" \
      SYMPHONY_VISIBLE_RUNNER="$runner" \
      "$launcher" >/dev/null 2>&1 &

    deadline=$((SECONDS + #{timeout_seconds}))
    while [ ! -f "$status_file" ]; do
      if [ "$SECONDS" -ge "$deadline" ]; then
        printf 'run_id=%s\\nlog=%s\\nstatus=running\\ntimed_out=true\\n' "$run_id" "$log"
        [ -f "$log" ] && tail -n 200 "$log"
        exit 124
      fi
      sleep 1
    done

    status="$(cat "$status_file")"
    printf 'run_id=%s\\nlog=%s\\nstatus=%s\\n\\n' "$run_id" "$log" "$status"
    tail -n 200 "$log"
    exit "$status"
    """
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp supported_tool_names(opts) do
    Enum.map(tool_specs(opts), & &1["name"])
  end
end

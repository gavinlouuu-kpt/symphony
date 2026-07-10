defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, Linear.Client, SSH}

  @linear_graphql_tool "linear_graphql"
  @sandbox_exec_tool "sandbox_exec"
  @sandbox_visible_exec_tool "sandbox_visible_exec"
  @sandbox_read_file_tool "sandbox_read_file"
  @sandbox_write_file_tool "sandbox_write_file"
  @evidence_tool "symphony_record_evidence"
  @thread_post_tool "symphony_thread_post"
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
  @evidence_tool_description """
  Run a required validation command inside the CUA sandbox and record it in Symphony's evidence ledger for gated PR handoff.
  """
  @thread_post_tool_description """
  Post a concise status update to this issue's Discord thread, optionally attaching one image/video/document from the sandbox workspace as visual evidence. Use at role milestones (plan ready, implementation done, validation verdict) and whenever the issue asks for visual proof.
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
  @evidence_tool_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["check", "command"],
    "properties" => %{
      "check" => %{
        "type" => "string",
        "description" => "Evidence check name. Use the exact configured evidence_contract.required_checks entry when one applies."
      },
      "command" => %{
        "type" => "string",
        "description" => "Shell command to run from the sandbox workspace."
      },
      "artifacts" => %{
        "type" => ["array", "null"],
        "description" => "Relative artifact paths that this command produced or verified.",
        "items" => %{"type" => "string"}
      }
    }
  }

  @thread_post_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["message"],
    "properties" => %{
      "message" => %{
        "type" => "string",
        "description" => "Short status update for the issue's Discord thread (plain text, keep under ~1500 chars)."
      },
      "media_path" => %{
        "type" => ["string", "null"],
        "description" => "Optional relative path (under the sandbox workspace) to an image/video/document to attach as visual evidence, e.g. .symphony/artifacts/screenshot.png."
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

      @evidence_tool ->
        execute_record_evidence(arguments, opts)

      @thread_post_tool ->
        execute_thread_post(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names(opts)
          }
        })
    end
  end

  @doc """
  Checks the configured handoff evidence contract against the sandbox evidence ledger.

  Expects a sandbox context with `:worker_host` and `:workspace`. Returns `:ok` when the
  contract is not enforced or satisfied, `{:error, missing}` with the unmet requirements
  otherwise.
  """
  @spec handoff_evidence_status(map()) :: :ok | {:error, term()}
  def handoff_evidence_status(%{worker_host: worker_host, workspace: workspace} = sandbox)
      when is_binary(worker_host) and is_binary(workspace) do
    settings = Config.settings!()

    case settings.evidence_contract.enforced do
      true -> evidence_contract_satisfied?(settings.evidence_contract, sandbox)
      _ -> :ok
    end
  end

  def handoff_evidence_status(_sandbox), do: {:error, :missing_sandbox_context}

  @spec tool_specs() :: [map()]
  @spec tool_specs(keyword()) :: [map()]
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
          },
          %{
            "name" => @evidence_tool,
            "description" => @evidence_tool_description,
            "inputSchema" => @evidence_tool_input_schema
          }
        ] ++ thread_post_specs()
    else
      base_specs
    end
  end

  defp thread_post_specs do
    if openclaw_outbound_enabled?() do
      [
        %{
          "name" => @thread_post_tool,
          "description" => @thread_post_tool_description,
          "inputSchema" => @thread_post_input_schema
        }
      ]
    else
      []
    end
  end

  defp openclaw_outbound_enabled? do
    Config.settings!().openclaw.enabled == true
  rescue
    _error -> false
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &configured_linear_graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp configured_linear_graphql(query, variables, opts) do
    client_module = Application.get_env(:symphony_elixir, :linear_client_module, Client)

    cond do
      function_exported?(client_module, :graphql, 3) ->
        client_module.graphql(query, variables, opts)

      function_exported?(client_module, :graphql, 2) ->
        client_module.graphql(query, variables)

      true ->
        {:error, {:missing_linear_graphql_client, client_module}}
    end
  end

  defp execute_sandbox_exec(arguments, opts) do
    with {:ok, sandbox} <- sandbox_context(opts),
         {:ok, command} <- normalize_command(arguments),
         :ok <- authorize_sandbox_command(command, sandbox),
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
         :ok <- authorize_sandbox_command(command, sandbox),
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

  defp execute_record_evidence(arguments, opts) do
    with {:ok, sandbox} <- sandbox_context(opts),
         {:ok, check, command, artifacts} <- normalize_evidence_arguments(arguments),
         :ok <- authorize_sandbox_command(command, sandbox),
         {:ok, {output, status}} <-
           SSH.run(
             sandbox.worker_host,
             "cd #{shell_escape(sandbox.workspace)} && #{command}",
             stderr_to_stdout: true
           ),
         {:ok, artifact_results} <- inspect_evidence_artifacts(sandbox, artifacts),
         :ok <- append_evidence_entry(sandbox, check, command, status, output, artifact_results) do
      dynamic_tool_response(
        status == 0,
        encode_payload(%{
          "status" => status,
          "output" => output,
          "evidence" => %{
            "check" => check,
            "command" => command,
            "artifacts" => artifact_results
          }
        })
      )
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_thread_post(arguments, opts) do
    with {:ok, sandbox} <- sandbox_context(opts),
         {:ok, message} <- normalize_thread_post_message(arguments),
         {:ok, target} <- resolve_thread_post_target(sandbox),
         {:ok, media_file, cleanup} <- fetch_thread_post_media(sandbox, arguments),
         :ok <- deliver_thread_post(message, target, media_file, cleanup) do
      dynamic_tool_response(
        true,
        encode_payload(%{
          "target" => target,
          "media_attached" => is_binary(media_file)
        })
      )
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_thread_post_message(arguments) when is_map(arguments) do
    case Map.get(arguments, "message") || Map.get(arguments, :message) do
      message when is_binary(message) ->
        case String.trim(message) do
          "" -> {:error, :missing_thread_post_message}
          trimmed -> {:ok, String.slice(trimmed, 0, 1_800)}
        end

      _ ->
        {:error, :missing_thread_post_message}
    end
  end

  defp normalize_thread_post_message(_arguments), do: {:error, :missing_thread_post_message}

  # Never fall back to the project channel: status belongs in the issue thread,
  # and posting to the parent when the thread is briefly unknown floods it.
  defp resolve_thread_post_target(sandbox) do
    thread_ref =
      SymphonyElixir.OpenClaw.Notifier.issue_thread_ref(%{
        issue_id: Map.get(sandbox, :issue_id),
        identifier: Map.get(sandbox, :issue_identifier),
        issue_url: Map.get(sandbox, :issue_url)
      })

    case thread_ref do
      %{target: target} when is_binary(target) and target != "" ->
        {:ok, target}

      _ ->
        {:error, :missing_openclaw_thread_target}
    end
  end

  # Discord caps ordinary uploads; keep a conservative limit.
  @thread_post_max_media_bytes 8_000_000

  defp fetch_thread_post_media(sandbox, arguments) do
    case Map.get(arguments, "media_path") || Map.get(arguments, :media_path) do
      nil ->
        {:ok, nil, fn -> :ok end}

      "" ->
        {:ok, nil, fn -> :ok end}

      path when is_binary(path) ->
        with {:ok, safe_path} <- validate_relative_path(path),
             {:ok, {encoded, 0}} <-
               SSH.run(
                 sandbox.worker_host,
                 sandbox_file_script(sandbox.workspace, safe_path, "base64 < \"$target\""),
                 stderr_to_stdout: true
               ),
             {:ok, binary} <- decode_thread_post_media(encoded) do
          write_thread_post_media(binary, Path.basename(safe_path))
        else
          {:ok, {output, _status}} ->
            {:error, {:thread_post_media_unreadable, output |> to_string() |> String.slice(0, 2_000)}}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :invalid_thread_post_media_path}
    end
  end

  defp decode_thread_post_media(encoded) do
    case Base.decode64(String.replace(encoded, ~r/\s+/, "")) do
      {:ok, binary} when byte_size(binary) == 0 ->
        {:error, :thread_post_media_empty}

      {:ok, binary} when byte_size(binary) > @thread_post_max_media_bytes ->
        {:error, {:thread_post_media_too_large, byte_size(binary), @thread_post_max_media_bytes}}

      {:ok, binary} ->
        {:ok, binary}

      :error ->
        {:error, :thread_post_media_unreadable}
    end
  end

  defp write_thread_post_media(binary, basename) do
    dir = Path.join(System.tmp_dir!(), "symphony_thread_media")
    File.mkdir_p!(dir)
    file = Path.join(dir, "#{System.unique_integer([:positive])}-#{basename}")

    case File.write(file, binary) do
      :ok -> {:ok, file, fn -> File.rm(file) end}
      {:error, reason} -> {:error, {:thread_post_media_write_failed, reason}}
    end
  end

  defp deliver_thread_post(message, target, media_file, cleanup) do
    settings = Config.settings!().openclaw
    client = openclaw_client_module()

    cond do
      settings.enabled != true ->
        cleanup.()
        {:error, :openclaw_disabled}

      not (Code.ensure_loaded?(client) and function_exported?(client, :send_to_target, 4)) ->
        cleanup.()
        {:error, {:openclaw_client_missing_send_to_target, client}}

      true ->
        try do
          client.send_to_target(message, target, media_file, settings)
        after
          cleanup.()
        end
    end
  end

  defp openclaw_client_module do
    Application.get_env(:symphony_elixir, :openclaw_client_module, SymphonyElixir.OpenClaw.Client)
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

  defp normalize_evidence_arguments(arguments) when is_map(arguments) do
    with {:ok, check} <- normalize_evidence_check(arguments),
         {:ok, command} <- normalize_command(arguments),
         {:ok, artifacts} <- normalize_evidence_artifacts(arguments) do
      {:ok, check, command, artifacts}
    end
  end

  defp normalize_evidence_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_evidence_check(arguments) do
    case Map.get(arguments, "check") || Map.get(arguments, :check) do
      check when is_binary(check) ->
        case String.trim(check) do
          "" -> {:error, :missing_evidence_check}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_evidence_check}
    end
  end

  defp normalize_evidence_artifacts(arguments) do
    artifacts = Map.get(arguments, "artifacts") || Map.get(arguments, :artifacts) || []

    cond do
      is_nil(artifacts) ->
        {:ok, []}

      is_list(artifacts) ->
        artifacts
        |> Enum.reduce_while({:ok, []}, fn artifact, {:ok, acc} ->
          case validate_relative_path(to_string(artifact)) do
            {:ok, path} -> {:cont, {:ok, [path | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, paths} -> {:ok, Enum.reverse(paths)}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, :invalid_evidence_artifacts}
    end
  end

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
    payload
    |> sanitize_for_json()
    |> Jason.encode!(pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp sanitize_for_json(%{} = map) do
    Map.new(map, fn {key, value} ->
      {sanitize_json_key(key), sanitize_for_json(value)}
    end)
  end

  defp sanitize_for_json(list) when is_list(list) do
    Enum.map(list, &sanitize_for_json/1)
  end

  defp sanitize_for_json(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      String.replace_invalid(value)
    end
  end

  defp sanitize_for_json(value), do: value

  defp sanitize_json_key(key) when is_binary(key), do: sanitize_for_json(key)
  defp sanitize_json_key(key), do: key

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

  defp tool_error_payload(:missing_evidence_check) do
    %{
      "error" => %{
        "message" => "`symphony_record_evidence.check` must be a non-empty string."
      }
    }
  end

  defp tool_error_payload(:invalid_evidence_artifacts) do
    %{
      "error" => %{
        "message" => "`symphony_record_evidence.artifacts` must be a list of relative sandbox paths."
      }
    }
  end

  defp tool_error_payload({:handoff_evidence_contract_failed, missing}) do
    %{
      "error" => %{
        "message" =>
          "Blocked handoff command: Symphony evidence_contract requirements are not satisfied. Use `symphony_record_evidence` to run the required real validation commands and record artifact paths before marking the PR ready, merging, closing the issue, or removing the active routing label.",
        "missing" => missing
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

  defp tool_error_payload(:missing_thread_post_message) do
    %{
      "error" => %{
        "message" => "`symphony_thread_post.message` must be a non-empty string."
      }
    }
  end

  defp tool_error_payload(:missing_openclaw_thread_target) do
    %{
      "error" => %{
        "message" => "No Discord thread is registered for this issue yet. Do not post to the project channel; continue working and retry this tool at the next milestone."
      }
    }
  end

  defp tool_error_payload({:thread_post_media_too_large, size, max}) do
    %{
      "error" => %{
        "message" => "Media file is #{size} bytes; the limit is #{max} bytes. Downscale or crop the evidence file."
      }
    }
  end

  defp tool_error_payload({:thread_post_media_unreadable, output}) do
    %{
      "error" => %{
        "message" => "Could not read the media file from the sandbox workspace.",
        "output" => output
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Dynamic tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp sandbox_context(opts) do
    opts
    |> Keyword.get(:sandbox_context)
    |> normalize_sandbox_context()
  end

  defp normalize_sandbox_context(%{worker_host: worker_host, workspace: workspace} = context)
       when is_binary(worker_host) and is_binary(workspace) do
    {:ok, put_sandbox_issue_fields(%{worker_host: worker_host, workspace: workspace}, context)}
  end

  defp normalize_sandbox_context(%{"worker_host" => worker_host, "workspace" => workspace} = context)
       when is_binary(worker_host) and is_binary(workspace) do
    {:ok, put_sandbox_issue_fields(%{worker_host: worker_host, workspace: workspace}, context)}
  end

  defp normalize_sandbox_context(_context), do: {:error, :missing_sandbox_context}

  # Issue identity rides along so tools like symphony_thread_post can resolve
  # the issue's Discord thread.
  defp put_sandbox_issue_fields(sandbox, context) do
    [:issue_id, :issue_identifier, :issue_url]
    |> Enum.reduce(sandbox, fn key, acc ->
      case Map.get(context, key) || Map.get(context, Atom.to_string(key)) do
        value when is_binary(value) and value != "" -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

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

  defp authorize_sandbox_command(command, sandbox) do
    if handoff_command?(command) do
      settings = Config.settings!()

      case settings.evidence_contract.enforced do
        true ->
          case evidence_contract_satisfied?(settings.evidence_contract, sandbox) do
            :ok -> :ok
            {:error, missing} -> {:error, {:handoff_evidence_contract_failed, missing}}
          end

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp handoff_command?(command) when is_binary(command) do
    normalized = String.downcase(command)

    cond do
      Regex.match?(~r/(^|[;&|()\s])gh\s+pr\s+ready(\s|$)/, normalized) and
          not Regex.match?(~r/(^|\s)--undo(\s|$)/, normalized) ->
        true

      Regex.match?(~r/(^|[;&|()\s])gh\s+pr\s+merge(\s|$)/, normalized) ->
        true

      Regex.match?(~r/(^|[;&|()\s])gh\s+issue\s+close(\s|$)/, normalized) ->
        true

      Regex.match?(~r/(^|[;&|()\s])gh\s+issue\s+edit\b/, normalized) and
          Regex.match?(~r/(^|\s)--remove-label(\s|=|$)/, normalized) ->
        removes_active_routing_label?(normalized)

      true ->
        false
    end
  end

  defp removes_active_routing_label?(normalized_command) do
    active_labels =
      Config.settings!().openclaw.intake_labels
      |> Enum.map(&(String.trim(&1) |> String.downcase()))
      |> Enum.reject(&(&1 == ""))

    cond do
      active_labels == [] ->
        true

      true ->
        Enum.any?(active_labels, &String.contains?(normalized_command, &1))
    end
  end

  defp evidence_contract_satisfied?(contract, sandbox) do
    entries = read_evidence_entries(sandbox)

    missing =
      []
      |> missing_required_checks(contract.required_checks, entries)
      |> missing_required_commands(contract.required_commands, entries)
      |> missing_required_artifacts(contract.required_artifacts, entries, sandbox)

    case missing do
      [] -> :ok
      _ -> {:error, missing}
    end
  end

  defp missing_required_checks(missing, required_checks, entries) do
    successful_checks =
      entries
      |> Enum.filter(&successful_evidence?/1)
      |> Enum.map(&Map.get(&1, "check"))
      |> MapSet.new()

    missing ++
      Enum.flat_map(required_checks || [], fn check ->
        if MapSet.member?(successful_checks, check), do: [], else: [%{"check" => check}]
      end)
  end

  defp missing_required_commands(missing, required_commands, entries) do
    successful_commands =
      entries
      |> Enum.filter(&successful_evidence?/1)
      |> Enum.map(&Map.get(&1, "command"))
      |> MapSet.new()

    missing ++
      Enum.flat_map(required_commands || [], fn command ->
        if MapSet.member?(successful_commands, command), do: [], else: [%{"command" => command}]
      end)
  end

  defp missing_required_artifacts(missing, required_artifacts, entries, sandbox) do
    successful_artifacts =
      entries
      |> Enum.filter(&successful_evidence?/1)
      |> Enum.flat_map(fn entry ->
        entry
        |> Map.get("artifacts", [])
        |> Enum.filter(&(Map.get(&1, "exists") == true))
        |> Enum.map(&Map.get(&1, "path"))
      end)
      |> MapSet.new()

    missing ++
      Enum.flat_map(required_artifacts || [], fn artifact ->
        cond do
          MapSet.member?(successful_artifacts, artifact) ->
            []

          sandbox_artifact_exists?(sandbox, artifact) ->
            []

          true ->
            [%{"artifact" => artifact}]
        end
      end)
  end

  defp successful_evidence?(%{"status" => 0}), do: true
  defp successful_evidence?(_entry), do: false

  defp read_evidence_entries(sandbox) do
    case SSH.run(
           sandbox.worker_host,
           "cd #{shell_escape(sandbox.workspace)} && cat .symphony/evidence-ledger.jsonl 2>/dev/null",
           stderr_to_stdout: true
         ) do
      {:ok, {output, 0}} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, %{} = entry} -> [entry]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp inspect_evidence_artifacts(sandbox, artifacts) do
    results =
      Enum.map(artifacts, fn path ->
        %{
          "path" => path,
          "exists" => sandbox_artifact_exists?(sandbox, path)
        }
      end)

    {:ok, results}
  end

  defp sandbox_artifact_exists?(sandbox, path) do
    case validate_relative_path(path) do
      {:ok, safe_path} ->
        case SSH.run(
               sandbox.worker_host,
               sandbox_file_script(sandbox.workspace, safe_path, "test -e \"$target\""),
               stderr_to_stdout: true
             ) do
          {:ok, {_output, 0}} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp append_evidence_entry(sandbox, check, command, status, output, artifacts) do
    entry =
      %{
        "tool" => @evidence_tool,
        "recorded_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "check" => check,
        "command" => command,
        "status" => status,
        "output_preview" => output |> to_string() |> String.slice(0, 4_000),
        "artifacts" => artifacts
      }

    encoded = (Jason.encode!(entry) <> "\n") |> Base.encode64()

    case SSH.run(
           sandbox.worker_host,
           "cd #{shell_escape(sandbox.workspace)} && mkdir -p .symphony && printf %s #{shell_escape(encoded)} | base64 -d >> .symphony/evidence-ledger.jsonl",
           stderr_to_stdout: true
         ) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:evidence_ledger_write_failed, status, output}}
      {:error, reason} -> {:error, reason}
    end
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
    env_file="$run_dir/$run_id.env"
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

    {
      printf 'SYMPHONY_VISIBLE_WORKSPACE=%q\\n' "$workspace"
      printf 'SYMPHONY_VISIBLE_COMMAND=%q\\n' "$command"
      printf 'SYMPHONY_VISIBLE_LOG=%q\\n' "$log"
      printf 'SYMPHONY_VISIBLE_STATUS_FILE=%q\\n' "$status_file"
    } > "$env_file"

    cat > "$runner" <<'SYMPHONY_VISIBLE_RUNNER'
    #!/usr/bin/env bash
    set +e
    env_file="${1:?missing visible exec env file}"
    # Source a per-run env file instead of inherited terminal environment. Xfce
    # can reuse an existing terminal server with stale environment variables.
    . "$env_file"
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
    title="${1:?missing visible exec title}"
    runner="${2:?missing visible exec runner}"
    env_file="${3:?missing visible exec env file}"
    if command -v xfce4-terminal >/dev/null 2>&1; then
      printf -v terminal_command 'bash %q %q' "$runner" "$env_file"
      exec xfce4-terminal --title "$title" --command "$terminal_command"
    elif command -v x-terminal-emulator >/dev/null 2>&1; then
      exec x-terminal-emulator -T "$title" -e bash "$runner" "$env_file"
    elif command -v xterm >/dev/null 2>&1; then
      exec xterm -T "$title" -e bash "$runner" "$env_file"
    else
      echo "No terminal emulator found in CUA desktop image" >&2
      exit 127
    fi
    SYMPHONY_VISIBLE_LAUNCHER

    chmod 600 "$env_file"
    chmod +x "$runner" "$launcher"
    env DISPLAY="${DISPLAY:-:1}" \
      "$launcher" "$title" "$runner" "$env_file" >/dev/null 2>&1 &

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

defmodule Ourocode.Command.CapabilityPreflight do
  @moduledoc """
  Read-only capability resolution and preflight projection.

  This module is intentionally narrow: it resolves command-shaped input against
  the already-loaded command registry and projects what would run without
  executing, trusting, installing, or mutating plugin state.
  """

  alias Ourocode.Command.CapabilityPreflight.Projection
  alias Ourocode.Command.CapabilityPreflight.Trust
  alias Ourocode.Command.Registry

  @type status :: :ready | :blocked | :missing
  @type trust_status :: :trusted | :requires_approval | :unknown | :not_applicable

  @type t :: %{
          required(:status) => status(),
          required(:input) => String.t(),
          optional(:reason) => atom(),
          optional(:capability) => map(),
          optional(:match) => map(),
          optional(:trust) => map(),
          optional(:side_effects) => map()
        }

  @spec resolve(map(), String.t()) :: t()
  def resolve(registry, input) when is_map(registry) and is_binary(input) do
    case command_token(input) do
      {:shell, shell} ->
        shell_preflight(input, shell)

      {:error, reason} ->
        %{status: :missing, input: input, reason: reason}

      {:ok, token} ->
        case Registry.resolve(registry, token) do
          {:ok, resolved} -> preflight(input, resolved)
          :error -> %{status: :missing, input: input, reason: :unknown_capability}
        end
    end
  end

  defp command_token(input) do
    input
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2, trim: true)
    |> List.first()
    |> normalize_command_token()
  end

  defp normalize_command_token(nil), do: {:error, :empty_input}
  defp normalize_command_token(""), do: {:error, :empty_input}

  defp normalize_command_token(token) do
    cond do
      String.starts_with?(token, "/") -> {:ok, token}
      token == "ooo" -> {:ok, "/ooo"}
      shell_command_token?(token) -> {:shell, token}
      true -> {:error, :not_command_shaped}
    end
  end

  defp shell_command_token?(token) do
    token in ~w(git mix npm pnpm yarn bun node elixir iex cargo make ls pwd cat rg find sed awk
      grep head tail wc curl wget rm mv cp mkdir touch chmod chown sudo sh bash zsh python python3)
  end

  defp preflight(input, %{entry: entry, token: token, canonical: canonical, match: match}) do
    trust = Trust.boundary(entry)
    runnable? = Map.get(entry, :runnable?, false)
    availability = Map.get(entry, :availability, :stub)

    status =
      cond do
        availability != :available -> :blocked
        runnable? != true -> :blocked
        trust.status in [:requires_approval, :unknown] -> :blocked
        true -> :ready
      end

    %{
      status: status,
      input: input,
      reason: blocked_reason(status, availability, runnable?, trust),
      capability: Projection.capability(entry),
      match: %{token: token, canonical: canonical, type: match},
      trust: trust,
      side_effects: Projection.side_effects(entry)
    }
    |> drop_nil_reason()
  end

  defp blocked_reason(:ready, _availability, _runnable?, _trust), do: nil

  defp blocked_reason(:blocked, availability, _runnable?, _trust) when availability != :available,
    do: :unavailable

  defp blocked_reason(:blocked, _availability, false, _trust), do: :not_runnable

  defp blocked_reason(:blocked, _availability, _runnable?, %{status: :requires_approval}),
    do: :trust_requires_approval

  defp blocked_reason(:blocked, _availability, _runnable?, %{status: :unknown}),
    do: :trust_unknown

  defp blocked_reason(:blocked, _availability, _runnable?, _trust), do: :blocked

  defp drop_nil_reason(%{reason: nil} = preflight), do: Map.delete(preflight, :reason)
  defp drop_nil_reason(preflight), do: preflight

  defp shell_preflight(input, token) do
    risk = shell_risk(input, token)
    status = if risk.blocked?, do: :blocked, else: :ready

    %{
      status: status,
      input: input,
      reason: risk.reason,
      shell: %{
        command: token,
        risk: risk.level,
        category: risk.category,
        summary: risk.summary,
        review: risk.review
      },
      side_effects: %{
        execution: risk.execution,
        discovery: :shell_review,
        risk_class: risk.level
      }
    }
    |> drop_nil_reason()
  end

  defp shell_risk(input, token) do
    text = String.downcase(input)

    cond do
      String.contains?(text, ["| sh", "| bash", "curl ", "wget "]) and
          String.contains?(text, "|") ->
        risk(:critical, :network_pipe, true, :network_shell,
          "downloads data and pipes it into a shell",
          "blocked until the download and script are inspected separately"
        )

      token in ~w(rm sudo chmod chown) or String.contains?(text, [" rm ", " -rf", " --force"]) ->
        risk(:high, :destructive, true, :filesystem_write,
          "can delete or mutate files",
          "review affected paths and prefer a dry run or a narrower target"
        )

      token in ~w(curl wget) ->
        risk(:medium, :network, true, :network,
          "uses the network",
          "network execution needs explicit intent and inspected output"
        )

      String.starts_with?(text, "git status") or token in ~w(ls pwd cat rg find sed awk grep head tail wc) ->
        risk(:low, :read_only, false, :none,
          "appears read-only",
          "safe to inspect; still review unexpected arguments"
        )

      token in ~w(mv cp mkdir touch) ->
        risk(:medium, :filesystem_write, false, :filesystem_write,
          "writes inside the workspace if paths are project-local",
          "review paths before running"
        )

      token in ~w(git mix npm pnpm yarn bun node elixir iex cargo make python python3) ->
        risk(:medium, :developer_tool, false, :developer_tool,
          "may run project code or write build artifacts",
          "run after confirming project-local side effects are acceptable"
        )

      true ->
        risk(:low, :read_only, false, :none,
          "appears read-only",
          "safe to inspect; still review unexpected arguments"
        )
    end
  end

  defp risk(level, category, blocked?, execution, summary, review) do
    %{
      level: level,
      category: category,
      blocked?: blocked?,
      execution: execution,
      summary: summary,
      review: review,
      reason: if(blocked?, do: category, else: nil)
    }
  end
end

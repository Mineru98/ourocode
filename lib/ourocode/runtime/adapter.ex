defmodule Ourocode.Runtime.Adapter do
  @moduledoc """
  Behaviour for runtime route adapters.

  Dispatch stays above transport implementations: adapters own the next runtime
  step for a parsed task request, while transports continue to own only MCP I/O.
  """

  alias Ourocode.TaskRequest

  @type context :: map()
  @type result :: {:ok, term()} | {:error, term()}

  @callback execute(TaskRequest.t(), context()) :: result()
end

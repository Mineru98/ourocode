defmodule Ourocode.MCP.Transport.SSE.SessionIdentifier do
  @moduledoc """
  Selects a stable session identifier for SSE raw-event metadata.
  """

  alias Ourocode.MCP.Transport.Http

  @spec from_uri_and_external_ids(URI.t(), map()) :: String.t()
  def from_uri_and_external_ids(uri, external_ids) do
    external_session_identifier(external_ids) || query_session_identifier(uri) ||
      Http.request_target(uri)
  end

  defp external_session_identifier(external_ids) when is_map(external_ids) do
    Map.get(external_ids, "session_id") ||
      Map.get(external_ids, :session_id) ||
      Map.get(external_ids, "sessionId") ||
      Map.get(external_ids, :sessionId)
  end

  defp external_session_identifier(_external_ids), do: nil

  defp query_session_identifier(%{query: nil}), do: nil
  defp query_session_identifier(%{query: ""}), do: nil

  defp query_session_identifier(uri) do
    uri.query
    |> URI.decode_query()
    |> Map.get("session")
  rescue
    ArgumentError -> nil
  end
end

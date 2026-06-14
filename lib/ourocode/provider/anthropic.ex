defmodule Ourocode.Provider.Anthropic do
  @moduledoc """
  Claude Pro/Max OAuth + token store for the main-session LLM.

  ourocode hosts no model. This connects the main session to a user's Claude
  subscription through the OAuth client the Claude CLI uses, so `claude` can
  answer over the direct Messages API without spawning the CLI on each turn.
  The browser flow uses Claude's hosted callback and accepts a pasted code or
  redirect URL.
  """

  alias Ourocode.Provider.Anthropic.Auth
  alias Ourocode.Provider.Anthropic.Store
  alias Ourocode.Provider.Anthropic.Token

  @type tokens :: Token.tokens()

  defdelegate store_path, to: Store
  defdelegate load, to: Store
  defdelegate save(tokens), to: Store
  defdelegate clear, to: Store
  defdelegate signed_in?, to: Store

  defdelegate generate_pkce, to: Auth
  defdelegate authorize_url(challenge, state), to: Auth
  defdelegate authorize_url(challenge, state, redirect_uri), to: Auth
  defdelegate exchange(code, verifier, state), to: Auth
  defdelegate exchange(code, verifier, state, redirect_uri), to: Auth
  defdelegate refresh(tokens), to: Auth
  defdelegate authorization, to: Auth
  defdelegate redirect_uri, to: Auth

  defdelegate from_response(resp, now_ms), to: Token
  defdelegate expired?(tokens, now_ms), to: Token
  defdelegate usable?(tokens, now_ms), to: Token
end

defmodule Ourocode.Terminal.InterviewPanel.Hints do
  @moduledoc """
  Copy selection for interview and wonderTool block chrome.
  """

  @spec marker(boolean()) :: String.t()
  def marker(true), do: "INTERVIEW (paused)"
  def marker(false), do: "INTERVIEW"

  @spec session_hint(boolean()) :: String.t()
  def session_hint(true),
    do: "paused   type to talk to main   /answer <answer> submits to interview"

  def session_hint(false), do: "running   the main session is handling this   stays until it ends"

  @spec wonder_hint(boolean(), boolean()) :: String.t()
  def wonder_hint(true, _has_detection?),
    do: "type to talk to main session   answers resume the interview"

  def wonder_hint(false, true), do: "1-9 select   type free answer   /cancel decline   Esc pause"
  def wonder_hint(false, false), do: "type your answer + Enter   Esc pause"

  @spec wonder_pick_hint(boolean(), non_neg_integer()) :: String.t()
  def wonder_pick_hint(true, _question_count),
    do: "type to talk to main   /answer <answer> submits to interview"

  def wonder_pick_hint(false, question_count) when question_count > 1,
    do: "Up/Dn pick   Tab next question   Free answer row   Enter submit all   Esc pause"

  def wonder_pick_hint(false, _question_count),
    do: "Up/Dn pick   1-9 shortcut   Free answer row   Enter submit   Esc pause"
end

defmodule Ourocode.Terminal.InterviewPanel.Hints do
  @moduledoc """
  Copy selection for interview and wonderTool block chrome.
  """

  @spec marker(boolean()) :: String.t()
  def marker(true), do: "INTERVIEW (paused)"
  def marker(false), do: "INTERVIEW"

  @spec session_hint(boolean()) :: String.t()
  def session_hint(true),
    do: "paused   /answer <answer> resumes   /cancel stops interview"

  def session_hint(false), do: "drafting question"

  @spec wonder_hint(boolean(), boolean()) :: String.t()
  def wonder_hint(true, _has_detection?),
    do: "paused   /answer <text> resumes   /cancel stops interview"

  def wonder_hint(false, true), do: "/cancel stops"
  def wonder_hint(false, false), do: "plain answer"

  @spec wonder_pick_hint(boolean(), non_neg_integer()) :: String.t()
  def wonder_pick_hint(true, _question_count),
    do: "paused   /answer <text> resumes   /cancel stops interview"

  def wonder_pick_hint(false, question_count) when question_count > 1,
    do: "Tab switches question"

  def wonder_pick_hint(false, _question_count),
    do: ""
end

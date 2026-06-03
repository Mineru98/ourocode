defmodule Ourocode.Runtime.InterviewOptionSynthesizerTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewOptionSynthesizer

  test "prefers model supplied options before generic rows" do
    options =
      InterviewOptionSynthesizer.options(
        [
          %{label: "Reliability", description: "Fix breakage first"},
          %{"label" => "Packaging", "description" => "Focus on distribution"}
        ],
        "What should happen next?"
      )

    assert Enum.map(options, & &1["label"]) == ["Reliability", "Packaging"]
  end

  test "derives prompt candidate options when the prompt names tradeoffs" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "Should we focus on terminal polish, plugin install flow, or release packaging?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "terminal polish",
             "plugin install flow",
             "release packaging"
           ]
  end

  test "creates decision-oriented options when no candidates can be parsed" do
    options = InterviewOptionSynthesizer.options([], "What should this interview clarify?")

    assert Enum.map(options, & &1["label"]) == [
             "Define the desired outcome",
             "Clarify the target user"
           ]
  end

  test "does not turn sentence fragments into fake picker choices" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "What should the install flow prove: that a plugin can be discovered, installed, enabled, and used successfully end-to-end?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "Define the desired outcome",
             "Clarify the target user"
           ]
  end

  test "does not split parenthesized email service examples into broken choices" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "어떤 이메일 계정/서비스(Gmail, Outlook, Apple Mail/IMAP 등)를 우선 연결해야 하고, “중요한 이메일”은 어떤 기준으로 판단되길 원하시나요?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "Connect Gmail first",
             "Connect Outlook first",
             "Connect Apple Mail/IMAP first",
             "Define importance criteria"
           ]
  end

  test "creates onboarding-specific fallbacks for broad onboarding prompts" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "Who is the onboarding for, and what outcome should a successfully onboarded user reach?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "Define the target user",
             "Define the activation outcome",
             "Audit the existing flow"
           ]
  end

  test "creates audience-specific onboarding choices without repeating broad fallbacks" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "Which onboarding audience should we serve first?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "Existing agent users",
             "First-time plugin installers",
             "Internal builders"
           ]

    refute Enum.any?(options, &(&1["label"] == "Define the target user"))
  end

  test "creates completion-signal onboarding choices without repeating audience fallbacks" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "What completion signal proves onboarding worked?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "First guided run succeeds",
             "Plugin tools verify cleanly",
             "Next action is obvious"
           ]

    refute Enum.any?(options, &(&1["label"] == "Define the activation outcome"))
  end

  test "does not append broad onboarding fallbacks when parsed choices are specific" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "Should onboarding generate the smallest valid plugin structure or guide through template choice first?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "generate the smallest valid plugin structure",
             "guide through template choice first"
           ]
  end

  test "creates plugin scaffold fallbacks when no explicit options are present" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "What plugin structure should the onboarding create?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "Generate plugin structure",
             "Clarify plugin behavior"
           ]
  end

  test "creates workflow readiness fallbacks instead of repeating generic choices" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "Which core workflows must be proven end-to-end for the plugin readiness test, and what is the expected successful outcome for each one?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "Guided work starts and advances",
             "Plugin management views work",
             "Verification passes cleanly"
           ]
  end

  test "creates MCP tool readiness fallbacks when availability is the question" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "Are MCP tools available for the plugin, and what should ready mean?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "Plugin is loaded",
             "Tools are callable"
           ]
  end

  test "turns repeated dependent clauses into concrete picker choices" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "What should the install flow prove: that installation succeeds end-to-end for a real plugin, that failure cases produce correct diagnostics, that the UX/spec is complete, or that existing code/tests cover the flow?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "installation succeeds end-to-end for a real plugin",
             "failure cases produce correct diagnostics",
             "the UX/spec is complete",
             "existing code/tests cover the flow"
           ]
  end

  test "drops leading context when parsing comma-separated interview axes" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "For progress visibility, should the interview clarify current phase names, done criteria, or failure causes first?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "current phase names",
             "done criteria",
             "failure causes first"
           ]
  end

  test "prefers quoted Korean option candidates over comma-splitting examples" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "이 연구/프로토타입 계획에서 가장 먼저 검증하고 싶은 핵심 가설은 무엇인가요: “transformer layer 없이도 성능이 유지된다”, “AI가 생성한 훈련 신호로 AI를 개선할 수 있다”, “새 레이어 구조가 더 효율적이다”, 아니면 다른 주장인가요?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "transformer layer 없이도 성능이 유지된다",
             "AI가 생성한 훈련 신호로 AI를 개선할 수 있다",
             "새 레이어 구조가 더 효율적이다"
           ]
  end

  test "strips Korean example and choice-tail context from comma candidates" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "합성 데이터 패턴 학습에서 transformer baseline과 비교할 패턴을 무엇으로 고정할까요: 예를 들어 반복/복사, 괄호 짝 맞추기, 길이 일반화, 규칙 기반 시퀀스 변환 중 하나를 선택하고, 성공 기준은 정확도 기준 baseline 대비 ±N% 이내처럼 둘까요?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "반복/복사",
             "괄호 짝 맞추기",
             "길이 일반화",
             "규칙 기반 시퀀스 변환"
           ]
  end

  test "does not split explanatory comma lists without a choice signal" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "실험 설명에는 데이터 수집, 모델 학습, 평가 절차가 포함되어야 하나요?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "Define the desired outcome",
             "Clarify the target user"
           ]
  end

  test "creates Korean interview-flow options instead of English generic fallbacks" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "이번 라운드의 목표는 실제 기능 요구사항을 확정하는 것이 아니라, ooo interview가 질문을 정상적으로 이어가고 답변을 반영하는지 검증하는 것인가요? 그렇다면 “잘 동작한다”의 기준은 무엇인가요?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "질문이 다음 라운드로 이어진다",
             "답변이 다음 질문에 반영된다",
             "Seed 작성에 필요한 기준이 모인다"
           ]
  end

  test "creates Korean success-criteria options for broad criteria prompts" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "이 기능이 잘 동작한다는 기준은 무엇인가요?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "성공 기준을 먼저 정의",
             "검증 방법을 먼저 정의",
             "사용자 영향을 먼저 정의"
           ]
  end
end

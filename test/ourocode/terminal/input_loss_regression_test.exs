defmodule Ourocode.Terminal.InputLossRegressionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.KeyReader

  @chunk_sizes [1, 2, 3, 5, 7, 16, 64, 997]
  @human String.duplicate("the quick brown fox jumps over the lazy dog ", 20)
  @burst String.duplicate("paste-burst-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ ", 120)
  @ime String.duplicate("안녕하세요 저는 오로코드 한글 입력 테스트입니다 ", 20)
  @mixed String.duplicate("abc한글def가나다123ㅎㅏㄴ", 40)
  @emoji String.duplicate("🚀🔥🌟", 100)
  @paste_block String.duplicate("대량 붙여넣기 paste block 0123456789 🚀 ", 100)

  test "human typing survives every byte chunk boundary" do
    assert_profile_round_trips("human", @human)
  end

  test "large printable ASCII burst survives every byte chunk boundary" do
    assert byte_size(@burst) > 5_000
    assert_profile_round_trips("burst", @burst)
  end

  test "Korean IME text survives every byte chunk boundary" do
    assert String.length(@ime) > 200
    assert_profile_round_trips("ime", @ime)
  end

  test "mixed ASCII and Korean text survives every byte chunk boundary" do
    assert_profile_round_trips("mixed", @mixed)
  end

  test "four-byte emoji text survives every byte chunk boundary" do
    assert_profile_round_trips("emoji", @emoji)
  end

  test "bracketed paste remains one event when markers and content are split" do
    assert String.length(@paste_block) > 2_000
    input = "\e[200~" <> @paste_block <> "\e[201~"

    for chunk_size <- @chunk_sizes do
      {events, leftover} = decode_stream(input, chunk_size)

      assert leftover == "",
             "bracketed paste retained trailing bytes at chunk_size=#{chunk_size}: #{inspect(leftover)}"

      assert [event] = events

      assert event.key == :paste,
             "bracketed paste emitted #{inspect(event.key)} at chunk_size=#{chunk_size}"

      assert event.char == @paste_block,
             "bracketed paste corrupted at chunk_size=#{chunk_size}: expected #{String.length(@paste_block)} graphemes, got #{String.length(event.char)}"
    end
  end

  test "complete printable streams leave no trailing decoder state" do
    for {profile, input} <- profiles(), chunk_size <- @chunk_sizes do
      {_events, leftover} = decode_stream(input, chunk_size)

      assert leftover == "",
             "#{profile} retained #{byte_size(leftover)} trailing bytes at chunk_size=#{chunk_size}: #{inspect(leftover)}"
    end
  end

  test "stream decoding preserves printable grapheme counts" do
    for {profile, input} <- profiles(), chunk_size <- @chunk_sizes do
      {events, leftover} = decode_stream(input, chunk_size)
      reconstructed = reconstruct(events)

      assert leftover == "",
             "#{profile} retained trailing bytes at chunk_size=#{chunk_size}: #{inspect(leftover)}"

      assert String.length(reconstructed) == String.length(input),
             "#{profile} lost or added graphemes at chunk_size=#{chunk_size}: expected #{String.length(input)}, got #{String.length(reconstructed)}"
    end
  end

  defp assert_profile_round_trips(profile, input) do
    for chunk_size <- @chunk_sizes do
      {events, leftover} = decode_stream(input, chunk_size)
      reconstructed = reconstruct(events)

      assert leftover == "",
             "#{profile} retained #{byte_size(leftover)} trailing bytes at chunk_size=#{chunk_size}: #{inspect(leftover)}"

      assert reconstructed == input,
             "#{profile} corrupted at chunk_size=#{chunk_size}: expected #{String.length(input)} graphemes, got #{String.length(reconstructed)} (delta #{String.length(input) - String.length(reconstructed)})"
    end
  end

  defp decode_stream(input, chunk_size) do
    Enum.reduce(chunks(input, chunk_size), {[], ""}, fn chunk, {all_events, leftover} ->
      {events, rest} = KeyReader.decode(leftover <> chunk)
      {all_events ++ events, rest}
    end)
  end

  defp chunks(<<>>, _chunk_size), do: []

  defp chunks(input, chunk_size) do
    size = min(byte_size(input), chunk_size)
    <<chunk::binary-size(size), rest::binary>> = input
    [chunk | chunks(rest, chunk_size)]
  end

  defp reconstruct(events) do
    events
    |> Enum.filter(&(&1.key in [:char, :paste]))
    |> Enum.map_join(& &1.char)
  end

  defp profiles do
    [human: @human, burst: @burst, ime: @ime, mixed: @mixed, emoji: @emoji]
  end
end

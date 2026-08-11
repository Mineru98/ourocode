## 작업 요약

Windows runner에서 Erlang helper가 초기 프레임을 준비하는 시간이 1초를 넘길 수 있어, helper port 응답을 확인하는 테스트의 제한 시간을 5초로 조정했습니다. helper port의 실행·입출력 계약과 오류 경로는 변경하지 않았습니다.

## 변경 파일

- `test/ourocode/ipc/helper_port_test.exs`: 초기 프레임 응답 assertion에 5초의 명시적 제한 시간을 적용했습니다.

## 검증

- 실패 전: [Windows CI 31476919204](https://github.com/Mineru98/ourocode/actions/runs/31476919204)에서 `helper_port_test.exs:10`이 1,000ms timeout으로 실패했고, 총 2,599개 중 1개가 실패했습니다.
- 수정 후: [Windows CI 31510519560](https://github.com/Mineru98/ourocode/actions/runs/31510519560)이 성공했고, `2599 tests, 0 failures`를 확인했습니다.
- 로컬 `mix test`는 이 PC의 Elixir 1.20(OTP 29용)과 Erlang OTP 27 PATH 불일치로 실행하지 못했습니다. 최종 검증은 CI와 동일한 Elixir 1.18/OTP 27 Windows runner에서 수행했습니다.

## 증거

UI 변경이 아닌 Windows IPC 회귀 테스트 변경이므로 이미지 캡처 대신 CI 실행 로그를 before/after 증거로 기록했습니다.

## 작업 요약

Windows 사용자가 소스 체크아웃 없이도 설치 스크립트와 제거 스크립트를 내려받고,
README의 PowerShell 설치 명령을 실행할 수 있도록 안내를 보완했습니다.

## 변경 전후 증거

문서 전용 변경이므로 화면 캡처는 생략했습니다. 수정 전과 후의 전체 README 사본은
각각 `before/README.md`와 `after/README.md`에 보관했습니다.

## 변경 파일

- `README.md`

## 검증

- README에 적힌 순서로 `install.ps1`와 `uninstall.ps1`을 다운로드했습니다.
- GitHub Release `v0.1.15-beta-2`를 SHA-256 검증 후 임시 경로에 설치했습니다.
- 설치된 런처의 `ourocode --version`이 `ourocode 0.1.15-beta-2`를 출력했습니다.
- 제거 후 임시 설치 루트가 남지 않음을 확인했습니다.

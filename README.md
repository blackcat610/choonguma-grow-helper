# 춘구마 키우기 도우미 for macOS

카카오톡의 **춘구마 키우기** 미니게임 화면에서 컵 또는 숟가락·포크를 빠르게 인식하고, 지정한 키를 한 번씩 입력하는 macOS용 로컬 도우미입니다.

[![Build macOS app](https://github.com/blackcat610/choonguma-grow-helper/actions/workflows/build.yml/badge.svg)](https://github.com/blackcat610/choonguma-grow-helper/actions/workflows/build.yml)
[![Latest release](https://img.shields.io/github/v/release/blackcat610/choonguma-grow-helper)](https://github.com/blackcat610/choonguma-grow-helper/releases/latest)

> 이 프로젝트는 팬이 만든 비공식 도구이며 카카오 또는 카카오프렌즈와 제휴하거나 승인을 받은 프로젝트가 아닙니다.

## 주요 기능

- 화면 안의 노란색 음식 버튼과 하늘색 물 버튼을 기준으로 게임 위치 자동 탐색
- 빈 컵은 물, 회색 숟가락·포크는 음식으로 판별
- 음식의 주황색 반응과 컵 안의 하늘색 물을 감지해 같은 화면에서 연타 방지
- 색 공간 차이로 색을 놓칠 때 컵·식기의 형태 변화로 보조 판별
- 준비 자세 확인 `1~3프레임` 설정
- 입력 전 지연 `0~500ms` 설정, 기본값 `120ms`
- 전역 단축키 `F8`로 시작과 정지
- 모든 처리를 기기 안에서 수행하며 네트워크 전송이나 데이터 수집 없음

## 요구 사항

- macOS 13 Ventura 이상
- Apple Silicon 또는 Intel Mac
- 화면 및 시스템 오디오 기록 권한
- 손쉬운 사용 권한

## 다운로드와 실행

1. [최신 릴리스](https://github.com/blackcat610/choonguma-grow-helper/releases/latest)에서 `ChoongumaGrowHelper-macOS-universal.zip`을 받습니다.
2. 압축을 풀고 `춘구마 키우기 도우미.app`을 실행합니다.
3. 처음 한 번 **화면 및 시스템 오디오 기록**과 **손쉬운 사용** 권한을 허용합니다.
4. 권한을 바꾼 직후에는 앱을 완전히 종료한 뒤 다시 실행합니다.

이 릴리스는 개인 개발용 ad-hoc 서명이며 Apple 공증을 받지 않았습니다. macOS가 실행을 막으면 Finder에서 앱을 Control-클릭한 뒤 **열기**를 선택하세요.

## 사용법

1. 음식과 물에 대응하는 키를 지정합니다. 기본값은 `← 음식`, `→ 물`입니다.
2. 준비 자세 확인 프레임 수와 입력 전 지연을 선택합니다. 처음에는 `1프레임 + 120ms`를 권장합니다.
3. 미니게임 창을 화면에 보이게 두고 `F8` 또는 **시작**을 누릅니다.
4. 다시 `F8`을 누르면 즉시 정지합니다. 메뉴 막대의 컵 아이콘에서도 제어할 수 있습니다.

입력 지연 중 컵·식기가 사라지거나 종류가 바뀌면 대기 중인 입력은 취소됩니다. 한 번 입력한 뒤에는 색 또는 형태 반응을 실제로 확인해야 다음 입력이 가능합니다.

## 소스에서 빌드

Xcode Command Line Tools와 Swift 5.9 이상이 필요합니다.

```bash
git clone https://github.com/blackcat610/choonguma-grow-helper.git
cd choonguma-grow-helper
./scripts/build-release.sh
```

완료되면 `dist/`에 Universal 앱 ZIP과 SHA-256 체크섬이 생성됩니다.

## 개인정보 보호

앱은 ScreenCaptureKit으로 현재 화면을 메모리에서 분석하지만 프레임을 파일로 저장하지 않습니다. 분석 결과, 키 입력, 화면 내용은 외부 서버로 전송되지 않습니다.

## 주의 사항

화면 배율, 게임 디자인 또는 색상이 변경되면 인식률이 달라질 수 있습니다. 자동화 사용이 허용되는지는 대상 서비스의 이용약관을 확인하고 본인 책임으로 사용하세요.

## 라이선스

[MIT License](LICENSE)

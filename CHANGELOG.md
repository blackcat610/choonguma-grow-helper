# Changelog

## 1.1.0 - 2026-08-19

- Direct AXPress activation of the exposed `밥 주기` and `물 주기` buttons
- Automatic fallback to process-targeted key delivery when AXPress is unavailable
- Preloaded game-window-only accessibility lookup to remove first-input lag
- Faster initial game-location scan cadence
- Direct key delivery to the KakaoTalk process while another app has focus
- Selectable compatibility mode for the currently focused application
- Guard against starting direct-input mode before KakaoTalk is open
- Window-only ScreenCaptureKit filter for the Choonguma auxiliary window with audio disabled
- Optional automatic AXPress activation of the result screen's `게임 다시하기` button

## 1.0.0 - 2026-08-19

- Cup and utensil recognition using ScreenCaptureKit
- Feedback-aware single-input gate to prevent key spamming
- Color and structural fallback detection
- Configurable 0–500ms input delay with 120ms default
- Configurable 1–3 frame ready-state confirmation
- Universal macOS build for Apple Silicon and Intel

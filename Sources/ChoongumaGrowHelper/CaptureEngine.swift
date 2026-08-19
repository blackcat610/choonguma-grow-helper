import AppKit
import ApplicationServices
import CoreMedia
import CoreVideo
import ScreenCaptureKit

struct KeyBinding {
    let title: String
    let keyCode: CGKeyCode
}

enum InputDeliveryMode: Equatable {
    case accessibilityButton
    case kakaoProcessKey
    case frontmostKey

    var requiresKakaoTalk: Bool {
        self != .frontmostKey
    }
}

enum InputDeliveryResult {
    case accessibilityButton
    case kakaoProcessKey
    case accessibilityFallbackKey
    case frontmostKey
}

final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    var onStatus: ((String) -> Void)?
    var onRunningChanged: ((Bool) -> Void)?
    var onInput: ((GameChoice, Int, Double, Double, InputDeliveryResult) -> Void)?

    private let analyzer = FrameAnalyzer()
    private let captureQueue = DispatchQueue(label: "io.github.blackcat610.ChoongumaButtonHelper.capture", qos: .userInteractive)
    private let replayQueue = DispatchQueue(label: "io.github.blackcat610.ChoongumaButtonHelper.replay", qos: .userInitiated)
    private var stream: SCStream?
    private var replayTimer: DispatchSourceTimer?
    private var starting = false
    private var activeStartToken: UUID?
    private(set) var isRunning = false

    private var foodKey: CGKeyCode = 123
    private var waterKey: CGKeyCode = 124
    private var inputDeliveryMode: InputDeliveryMode = .frontmostKey
    private var autoReplayEnabled = true
    private var targetProcessID: pid_t?
    private var accessibilityButtons: AccessibilityButtonController?
    private var replayButtons: AccessibilityButtonController?
    private var inputGate = InputGate(requiredReadyFrames: 2)

    private var geometry: GameGeometry?
    private var frameNumber = 0
    private var invalidGeometryFrames = 0
    private var inputCount = 0
    private var lastInputChoice: GameChoice?
    private var replayWaitingForGame = false
    private var replayPollingEnabled = false
    private var replayAwaitingGame = false
    private var lastStatus = ""

    func start(
        foodKey: CGKeyCode,
        waterKey: CGKeyCode,
        requiredReadyFrames: Int,
        inputDelay: TimeInterval,
        inputDeliveryMode: InputDeliveryMode,
        autoReplay: Bool
    ) {
        guard !isRunning, !starting else { return }
        self.foodKey = foodKey
        self.waterKey = waterKey
        self.inputDeliveryMode = inputDeliveryMode
        self.autoReplayEnabled = autoReplay
        self.targetProcessID = nil
        self.accessibilityButtons = nil
        self.replayButtons = nil
        self.inputGate = InputGate(
            requiredReadyFrames: requiredReadyFrames,
            inputDelay: inputDelay
        )
        starting = true
        let startToken = UUID()
        activeStartToken = startToken
        resetRecognitionState()
        publishStatus("화면 캡처를 시작하는 중…")

        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                guard self.activeStartToken == startToken, self.starting else { return }
                guard let kakaoTalk = self.findKakaoTalk(in: content.applications) else {
                    throw CaptureError.kakaoTalkNotFound
                }
                guard let gameWindow = self.findGameWindow(
                    in: content.windows,
                    processID: kakaoTalk.processID
                ) else {
                    throw CaptureError.gameWindowNotFound
                }

                if inputDeliveryMode.requiresKakaoTalk {
                    self.targetProcessID = kakaoTalk.processID
                }
                if inputDeliveryMode == .accessibilityButton {
                    self.accessibilityButtons = AccessibilityButtonController(
                        processID: kakaoTalk.processID
                    )
                }
                if autoReplay {
                    self.replayButtons = AccessibilityButtonController(
                        processID: kakaoTalk.processID
                    )
                }

                // Only the KakaoTalk auxiliary game window enters this process.
                // Other applications and the rest of the display are never part of the stream.
                let filter = SCContentFilter(desktopIndependentWindow: gameWindow)

                let configuration = SCStreamConfiguration()
                let captureScale = self.captureScale(
                    for: gameWindow,
                    displays: content.displays
                )
                configuration.width = max(
                    1,
                    Int((gameWindow.frame.width * captureScale).rounded())
                )
                configuration.height = max(
                    1,
                    Int((gameWindow.frame.height * captureScale).rounded())
                )
                // ProMotion 화면에서는 최대 120fps, 일반 화면에서는 실제 주사율로 전달된다.
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
                configuration.queueDepth = 2
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.showsCursor = false
                configuration.capturesAudio = false
                if #available(macOS 14.0, *) {
                    configuration.ignoreShadowsSingleWindow = true
                }

                let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try newStream.addStreamOutput(
                    self,
                    type: .screen,
                    sampleHandlerQueue: self.captureQueue
                )
                try await newStream.startCapture()

                guard self.activeStartToken == startToken, self.starting else {
                    try? await newStream.stopCapture()
                    return
                }

                await MainActor.run {
                    self.stream = newStream
                    self.starting = false
                    self.activeStartToken = nil
                    self.isRunning = true
                    self.startReplayTimer()
                    self.onRunningChanged?(true)
                    let status: String
                    switch inputDeliveryMode {
                    case .accessibilityButton:
                        status = "게임 창 전용 캡처 · 버튼 직접 입력 준비됨"
                    case .kakaoProcessKey:
                        status = "게임 창 전용 캡처 · 카카오톡 직접 키 준비됨"
                    case .frontmostKey:
                        status = "게임 창 전용 캡처 준비됨"
                    }
                    self.publishStatus(status)
                }
            } catch {
                await MainActor.run {
                    guard self.activeStartToken == startToken else { return }
                    self.activeStartToken = nil
                    self.starting = false
                    self.isRunning = false
                    self.stream = nil
                    self.stopReplayTimer()
                    self.targetProcessID = nil
                    self.accessibilityButtons = nil
                    self.replayButtons = nil
                    self.onRunningChanged?(false)
                    self.publishStatus("캡처 시작 실패: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        guard isRunning || starting else { return }
        activeStartToken = nil
        starting = false
        isRunning = false
        let oldStream = stream
        stream = nil
        stopReplayTimer()
        targetProcessID = nil
        accessibilityButtons = nil
        replayButtons = nil
        resetRecognitionState()
        onRunningChanged?(false)
        publishStatus("정지됨")

        Task {
            try? await oldStream?.stopCapture()
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, isRunning,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let rawAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let pixels = UnsafeRawPointer(rawAddress).assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        processFrame(pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stream = nil
            self.stopReplayTimer()
            self.starting = false
            self.isRunning = false
            self.targetProcessID = nil
            self.accessibilityButtons = nil
            self.replayButtons = nil
            self.onRunningChanged?(false)
            self.publishStatus("화면 캡처 중단: \(error.localizedDescription)")
        }
    }

    private func processFrame(
        pixels: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) {
        frameNumber += 1

        if let currentGeometry = geometry {
            if analyzer.geometryStillValid(
                currentGeometry,
                pixels: pixels,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow
            ) {
                invalidGeometryFrames = 0
            } else {
                geometry = nil
                invalidGeometryFrames = 1
                resetRoundState()
                beginReplayPolling()
                publishStatus("게임 종료 확인 중…")
                return
            }
        } else {
            guard frameNumber % 4 == 0 else { return }
            guard let found = analyzer.locateGame(
                pixels: pixels,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow
            ) else {
                publishStatus(
                    replayWaitingForGame ? "다시 시작하는 중…" : "게임 화면을 찾는 중…"
                )
                return
            }
            geometry = found
            invalidGeometryFrames = 0
            resetRoundState()
            let didReplay = replayWaitingForGame
            replayWaitingForGame = false
            endReplayPolling()
            accessibilityButtons?.prepare()
            publishStatus(
                didReplay ? "새 게임 인식됨 · 첫 문제 대기 중" : "게임 인식됨 · 첫 문제 대기 중"
            )
        }

        guard let geometry else { return }
        let observation = analyzer.observe(
            geometry: geometry,
            pixels: pixels,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )

        // 고정 대기시간을 쓰지 않는다. 입력 후 색 반응을 실제로 본 다음,
        // 준비 자세가 다시 나타난 첫 안정 프레임에서만 한 번 입력한다.
        let hadSeenFeedback = inputGate.sawExpectedFeedback
        let nextChoice = inputGate.update(with: observation)
        if !hadSeenFeedback, inputGate.sawExpectedFeedback {
            NSLog(
                "[ChoongumaGrowHelper] feedback confirmed after %@; orange=%.0f cyan=%.0f white=%.0f gray=%.0f",
                lastInputChoice?.rawValue ?? "unknown",
                observation.orangeFeedbackScore,
                observation.cyanFeedbackScore,
                observation.whiteScore,
                observation.grayScore
            )
        }
        if let choice = nextChoice {
            press(choice, observation: observation)
        }
    }

    private func press(_ choice: GameChoice, observation: FrameObservation) {
        let keyCode = choice == .food ? foodKey : waterKey
        let deliveryResult = deliver(choice, keyCode: keyCode)
        inputCount += 1
        lastInputChoice = choice
        NSLog(
            "[ChoongumaGrowHelper] input %@ #%d; white=%.0f gray=%.0f",
            choice.rawValue,
            inputCount,
            observation.whiteScore,
            observation.grayScore
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onInput?(
                choice,
                self.inputCount,
                observation.whiteScore,
                observation.grayScore,
                deliveryResult
            )
        }
    }

    private func startReplayTimer() {
        guard autoReplayEnabled, replayTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: replayQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(50),
            repeating: .milliseconds(100),
            leeway: .milliseconds(20)
        )
        timer.setEventHandler { [weak self] in self?.pollReplayButton() }
        replayTimer = timer
        replayQueue.async { [weak self] in
            self?.replayPollingEnabled = true
            self?.replayAwaitingGame = false
        }
        timer.resume()
    }

    private func stopReplayTimer() {
        replayTimer?.setEventHandler {}
        replayTimer?.cancel()
        replayTimer = nil
        replayQueue.async { [weak self] in
            self?.replayPollingEnabled = false
            self?.replayAwaitingGame = false
        }
    }

    private func beginReplayPolling() {
        guard autoReplayEnabled else { return }
        replayQueue.async { [weak self] in
            self?.replayPollingEnabled = true
            self?.replayAwaitingGame = false
        }
    }

    private func endReplayPolling() {
        replayQueue.async { [weak self] in
            self?.replayPollingEnabled = false
            self?.replayAwaitingGame = false
        }
    }

    private func pollReplayButton() {
        guard replayPollingEnabled,
              isRunning,
              let replayButtons,
              replayButtons.pressReplay() else { return }

        replayPollingEnabled = false
        replayAwaitingGame = true
        captureQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.replayWaitingForGame = true
            self.geometry = nil
            self.invalidGeometryFrames = 0
            self.resetRoundState()
            self.publishStatus("게임 종료 감지 · 자동으로 다시하기 누름")
        }
        replayQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.replayAwaitingGame else { return }
            self.replayPollingEnabled = true
        }
    }

    private func deliver(_ choice: GameChoice, keyCode: CGKeyCode) -> InputDeliveryResult {
        if inputDeliveryMode == .accessibilityButton {
            if accessibilityButtons?.press(choice) == true {
                return .accessibilityButton
            }
            NSLog(
                "[ChoongumaGrowHelper] AXPress unavailable for %@; falling back to targeted key",
                choice.rawValue
            )
            postKey(keyCode)
            return .accessibilityFallbackKey
        }

        postKey(keyCode)
        return inputDeliveryMode == .kakaoProcessKey ? .kakaoProcessKey : .frontmostKey
    }

    private func postKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        let destinationPID = targetProcessID
        if let destinationPID, let keyDown {
            keyDown.postToPid(destinationPID)
        } else {
            keyDown?.post(tap: .cghidEventTap)
        }
        captureQueue.asyncAfter(deadline: .now() + 0.006) {
            if let destinationPID, let keyUp {
                keyUp.postToPid(destinationPID)
            } else {
                keyUp?.post(tap: .cghidEventTap)
            }
        }
    }

    private func findKakaoTalk(in applications: [SCRunningApplication]) -> SCRunningApplication? {
        if let exact = applications.first(where: {
            $0.bundleIdentifier == "com.kakao.KakaoTalkMac"
        }) {
            return exact
        }
        return applications.first {
            $0.bundleIdentifier.localizedCaseInsensitiveContains("kakao") &&
            $0.applicationName.localizedCaseInsensitiveContains("kakao")
        }
    }

    private func findGameWindow(in windows: [SCWindow], processID: pid_t) -> SCWindow? {
        let candidates = windows.filter {
            $0.owningApplication?.processID == processID && gameWindowScore($0) > 0
        }
        return candidates.max { gameWindowScore($0) < gameWindowScore($1) }
    }

    private func gameWindowScore(_ window: SCWindow) -> Double {
        let width = window.frame.width
        let height = window.frame.height
        guard width >= 350, width <= 500,
              height >= 550, height <= 750 else { return -Double.infinity }

        let aspect = width / max(1, height)
        var score = 10_000 - abs(aspect - 0.656) * 1_000
        if window.title == "스노보드 초비상대책위원회" {
            score += 500
        }
        return score
    }

    private func captureScale(for window: SCWindow, displays: [SCDisplay]) -> CGFloat {
        let matchingDisplay = displays.max { left, right in
            intersectionArea(left.frame, window.frame) < intersectionArea(right.frame, window.frame)
        }
        guard let display = matchingDisplay,
              display.frame.width > 0,
              display.frame.height > 0 else { return 2 }

        let scaleX = CGFloat(display.width) / display.frame.width
        let scaleY = CGFloat(display.height) / display.frame.height
        return min(4, max(1, min(scaleX, scaleY)))
    }

    private func intersectionArea(_ left: CGRect, _ right: CGRect) -> CGFloat {
        let intersection = left.intersection(right)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private func resetRecognitionState() {
        geometry = nil
        frameNumber = 0
        invalidGeometryFrames = 0
        inputCount = 0
        lastInputChoice = nil
        replayWaitingForGame = false
        resetRoundState()
    }

    private func resetRoundState() {
        inputGate.reset()
    }

    private func publishStatus(_ text: String) {
        guard text != lastStatus else { return }
        lastStatus = text
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(text)
        }
    }
}

private enum CaptureError: LocalizedError {
    case kakaoTalkNotFound
    case gameWindowNotFound

    var errorDescription: String? {
        switch self {
        case .kakaoTalkNotFound:
            return "카카오톡을 찾을 수 없습니다. 카카오톡과 게임 창을 먼저 여세요."
        case .gameWindowNotFound:
            return "춘구마 게임 창을 찾을 수 없습니다. 게임 보조 창을 연 뒤 다시 시작하세요."
        }
    }
}

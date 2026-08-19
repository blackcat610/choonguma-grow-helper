import AppKit
import ApplicationServices
import CoreMedia
import CoreVideo
import ScreenCaptureKit

struct KeyBinding {
    let title: String
    let keyCode: CGKeyCode
}

final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    var onStatus: ((String) -> Void)?
    var onRunningChanged: ((Bool) -> Void)?
    var onInput: ((GameChoice, Int, Double, Double) -> Void)?

    private let analyzer = FrameAnalyzer()
    private let captureQueue = DispatchQueue(label: "io.github.blackcat610.ChoongumaGrowHelper.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var starting = false
    private var activeStartToken: UUID?
    private(set) var isRunning = false

    private var foodKey: CGKeyCode = 123
    private var waterKey: CGKeyCode = 124
    private var inputGate = InputGate(requiredReadyFrames: 2)

    private var geometry: GameGeometry?
    private var frameNumber = 0
    private var invalidGeometryFrames = 0
    private var inputCount = 0
    private var lastInputChoice: GameChoice?
    private var lastStatus = ""

    func start(
        foodKey: CGKeyCode,
        waterKey: CGKeyCode,
        requiredReadyFrames: Int,
        inputDelay: TimeInterval
    ) {
        guard !isRunning, !starting else { return }
        self.foodKey = foodKey
        self.waterKey = waterKey
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
                guard let display = await MainActor.run(body: {
                    self.chooseDisplay(from: content.displays)
                }) else {
                    throw CaptureError.noDisplay
                }

                let ownApplication = content.applications.first {
                    $0.bundleIdentifier == Bundle.main.bundleIdentifier
                }
                let excludedApplications = ownApplication.map { [$0] } ?? []
                let filter = SCContentFilter(
                    display: display,
                    excludingApplications: excludedApplications,
                    exceptingWindows: []
                )

                let configuration = SCStreamConfiguration()
                configuration.width = display.width
                configuration.height = display.height
                // ProMotion 화면에서는 최대 120fps, 일반 화면에서는 실제 주사율로 전달된다.
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
                configuration.queueDepth = 2
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.showsCursor = false
                configuration.capturesAudio = false

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
                    self.onRunningChanged?(true)
                    self.publishStatus("게임 화면을 찾는 중…")
                }
            } catch {
                await MainActor.run {
                    guard self.activeStartToken == startToken else { return }
                    self.activeStartToken = nil
                    self.starting = false
                    self.isRunning = false
                    self.stream = nil
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
            self.starting = false
            self.isRunning = false
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
            if frameNumber % 3 == 0 {
                if analyzer.geometryStillValid(
                    currentGeometry,
                    pixels: pixels,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow
                ) {
                    invalidGeometryFrames = 0
                } else {
                    invalidGeometryFrames += 1
                    if invalidGeometryFrames >= 3 {
                        geometry = nil
                        resetRoundState()
                        publishStatus("게임 위치를 다시 찾는 중…")
                        return
                    }
                }
            }
        } else {
            guard frameNumber % 8 == 0 else { return }
            guard let found = analyzer.locateGame(
                pixels: pixels,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow
            ) else {
                publishStatus("게임 화면을 찾는 중…")
                return
            }
            geometry = found
            invalidGeometryFrames = 0
            resetRoundState()
            publishStatus("게임 인식됨 · 첫 문제 대기 중")
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
        postKey(keyCode)
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
            self.onInput?(choice, self.inputCount, observation.whiteScore, observation.grayScore)
        }
    }

    private func postKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        captureQueue.asyncAfter(deadline: .now() + 0.006) {
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    private func chooseDisplay(from displays: [SCDisplay]) -> SCDisplay? {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let exact = displays.first(where: { $0.displayID == CGDirectDisplayID(number.uint32Value) }) {
            return exact
        }
        return displays.first
    }

    private func resetRecognitionState() {
        geometry = nil
        frameNumber = 0
        invalidGeometryFrames = 0
        inputCount = 0
        lastInputChoice = nil
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
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "캡처할 디스플레이를 찾을 수 없습니다."
        }
    }
}

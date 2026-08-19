import CoreGraphics
import Foundation
import ImageIO

enum SelfTestRunner {
    static func run(paths: [String]) -> Int32 {
        let analyzer = FrameAnalyzer()
        var failures = runInputGateTest()

        for path in paths {
            guard let image = loadImage(path: path) else {
                print("FAIL  \(path): 이미지를 읽을 수 없음")
                failures += 1
                continue
            }

            let width = image.width
            let height = image.height
            let bytesPerRow = width * 4
            var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            )

            let drewImage = buffer.withUnsafeMutableBytes { rawBuffer -> Bool in
                guard let context = CGContext(
                    data: rawBuffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo.rawValue
                ) else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }

            guard drewImage else {
                print("FAIL  \(path): 픽셀 버퍼 생성 실패")
                failures += 1
                continue
            }

            let result: (GameGeometry?, FrameObservation?) = buffer.withUnsafeBytes { rawBuffer in
                let pixels = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
                let geometry = analyzer.locateGame(
                    pixels: pixels,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow
                )
                let observation = geometry.map {
                    analyzer.observe(
                        geometry: $0,
                        pixels: pixels,
                        width: width,
                        height: height,
                        bytesPerRow: bytesPerRow
                    )
                }
                return (geometry, observation)
            }

            let filename = URL(fileURLWithPath: path).lastPathComponent
            let expected = expectedObservation(filename: filename)
            let actualChoice = result.1?.choice
            let actualFeedback = result.1?.feedbackChoice
            let geometryText: String
            if let geometry = result.0 {
                geometryText = "중심 \(Int(geometry.centerX)),\(Int(geometry.buttonCenterY)) 배율 \(String(format: "%.2f", geometry.scale))"
            } else {
                geometryText = "활성 게임 없음"
            }
            let scores = result.1.map {
                " 흰색 \(Int($0.whiteScore)) 회색 \(Int($0.grayScore))" +
                " 주황 \(Int($0.orangeFeedbackScore)) 하늘 \(Int($0.cyanFeedbackScore))"
            } ?? ""

            guard let expected else {
                print(
                    "INFO  \(filename): 준비 \(actualChoice?.rawValue ?? "없음"), " +
                    "반응 \(actualFeedback?.rawValue ?? "없음") · \(geometryText)\(scores)"
                )
                continue
            }

            let geometryMatches = (result.0 != nil) == expected.hasGame
            if actualChoice == expected.choice,
               actualFeedback == expected.feedback,
               geometryMatches {
                print(
                    "PASS  \(filename): 준비 \(actualChoice?.rawValue ?? "없음"), " +
                    "반응 \(actualFeedback?.rawValue ?? "없음") · \(geometryText)\(scores)"
                )
            } else {
                print(
                    "FAIL  \(filename): 예상 준비 \(expected.choice?.rawValue ?? "없음")/" +
                    "반응 \(expected.feedback?.rawValue ?? "없음"), 실제 준비 " +
                    "\(actualChoice?.rawValue ?? "없음")/반응 \(actualFeedback?.rawValue ?? "없음") · " +
                    "\(geometryText)\(scores)"
                )
                failures += 1
            }
        }
        return failures == 0 ? 0 : 1
    }

    private static func loadImage(path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private struct ExpectedObservation {
        let hasGame: Bool
        let choice: GameChoice?
        let feedback: GameChoice?
    }

    private static func expectedObservation(filename: String) -> ExpectedObservation? {
        if filename.contains("12.09.36") {
            return ExpectedObservation(hasGame: false, choice: nil, feedback: nil)
        }
        if filename.contains("12.09.42") || filename.contains("12.09.51") {
            return ExpectedObservation(hasGame: true, choice: .water, feedback: nil)
        }
        if filename.contains("12.09.45") {
            return ExpectedObservation(hasGame: true, choice: .food, feedback: nil)
        }

        let foodReady = ["007500", "011000", "011500"]
        if foodReady.contains(where: filename.contains) {
            return ExpectedObservation(hasGame: true, choice: .food, feedback: nil)
        }
        let waterReady = ["008733", "009100", "009600", "010300"]
        if waterReady.contains(where: filename.contains) {
            return ExpectedObservation(hasGame: true, choice: .water, feedback: nil)
        }
        let foodFeedback = ["007600", "007800", "008417", "011800"]
        if foodFeedback.contains(where: filename.contains) {
            return ExpectedObservation(hasGame: true, choice: nil, feedback: .food)
        }
        let waterFeedback = ["009300", "010000", "010683"]
        if waterFeedback.contains(where: filename.contains) {
            return ExpectedObservation(hasGame: true, choice: nil, feedback: .water)
        }
        return nil
    }

    private static func runInputGateTest() -> Int {
        var gate = InputGate(requiredReadyFrames: 1)
        var actual: [GameChoice] = []

        func observation(
            choice: GameChoice? = nil,
            feedback: GameChoice? = nil,
            whiteScore: Double? = nil,
            grayScore: Double? = nil
        ) -> FrameObservation {
            FrameObservation(
                choice: choice,
                feedbackChoice: feedback,
                whiteScore: whiteScore ?? (choice == .water ? 2_500 : 0),
                grayScore: grayScore ?? (choice == .food ? 1_200 : 0),
                orangeFeedbackScore: feedback == .food ? 1_300 : 0,
                cyanFeedbackScore: feedback == .water ? 1_300 : 0
            )
        }

        let sequence: [FrameObservation] = [
            observation(choice: .food),            // 첫 음식 입력
            observation(choice: .food),
            observation(choice: .food),
            observation(choice: .food),
            observation(choice: .food),            // 같은 화면에서는 추가 입력 금지
            observation(feedback: .food),
            observation(feedback: .food),
            observation(choice: .food),            // 반응 후 두 번째 음식 입력
            observation(choice: .food),
            observation(choice: .water),            // 반응 전 프롬프트 변화만으로 해제 금지
            observation(feedback: .food),
            observation(choice: .water),            // 음식 반응 후 물 입력
            observation(choice: .water),
            observation(feedback: .food),           // 잘못된 종류의 반응은 해제 금지
            observation(choice: .food),
            observation(feedback: .water),
            observation(choice: .food),             // 물 반응 후 음식 입력
            observation(choice: .food)
        ]

        for item in sequence {
            if let choice = gate.update(with: item) {
                actual.append(choice)
            }
        }

        var structuralGate = InputGate(requiredReadyFrames: 1)
        var structuralActual: [GameChoice] = []
        let structuralSequence = [
            observation(choice: .food, grayScore: 1_500),
            observation(choice: .food, grayScore: 900),
            observation(choice: .food, grayScore: 900),
            observation(choice: .water, whiteScore: 2_600),
            observation(whiteScore: 700),
            observation(whiteScore: 700),
            observation(choice: .food, grayScore: 1_500)
        ]
        for item in structuralSequence {
            if let choice = structuralGate.update(with: item) {
                structuralActual.append(choice)
            }
        }

        var delayedGate = InputGate(requiredReadyFrames: 1, inputDelay: 0.120)
        var delayedActual: [(TimeInterval, GameChoice)] = []
        let delayedSequence: [(TimeInterval, FrameObservation)] = [
            (0.000, observation(choice: .food)),
            (0.060, observation(choice: .food)),
            (0.119, observation(choice: .food)),
            (0.120, observation(choice: .food)),
            (0.180, observation(choice: .food)),
            (0.250, observation(feedback: .food)),
            (0.300, observation(choice: .water)),
            (0.419, observation(choice: .water)),
            (0.420, observation(choice: .water))
        ]
        for (timestamp, item) in delayedSequence {
            if let choice = delayedGate.update(with: item, at: timestamp) {
                delayedActual.append((timestamp, choice))
            }
        }

        let expected: [GameChoice] = [.food, .food, .water, .food]
        let structuralExpected: [GameChoice] = [.food, .water, .food]
        let delayedChoices = delayedActual.map(\.1)
        let delayedTimes = delayedActual.map(\.0)
        let delayedExpected: [GameChoice] = [.food, .water]
        if actual == expected,
           structuralActual == structuralExpected,
           delayedChoices == delayedExpected,
           delayedTimes == [0.120, 0.420] {
            print("PASS  입력 게이트: 색·형태 잠금 및 120ms 입력 지연")
            return 0
        }
        print(
            "FAIL  입력 게이트: 색 예상 \(expected.map(\.rawValue))/실제 \(actual.map(\.rawValue)), " +
            "형태 예상 \(structuralExpected.map(\.rawValue))/실제 \(structuralActual.map(\.rawValue)), " +
            "지연 실제 \(delayedActual)"
        )
        return 1
    }
}

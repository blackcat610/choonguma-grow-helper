import CoreGraphics
import Foundation
import ImageIO

enum SequenceTestRunner {
    static func run(paths: [String]) -> Int32 {
        let analyzer = FrameAnalyzer()
        var gate = InputGate(requiredReadyFrames: 1, inputDelay: 0.120)
        var geometry: GameGeometry?
        var inputs: [(String, GameChoice)] = []
        var analyzedFrames = 0
        var feedbackFrames = 0
        var previousObservation: FrameObservation?
        var previousTimestamp: TimeInterval?

        for path in paths.sorted() {
            guard let image = loadImage(path: path) else {
                print("FAIL  연속 프레임 읽기 실패: \(path)")
                return 1
            }

            let width = image.width
            let height = image.height
            let bytesPerRow = width * 4
            var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
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
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo.rawValue
                ) else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drewImage else {
                print("FAIL  연속 프레임 픽셀 변환 실패: \(path)")
                return 1
            }

            let observation: FrameObservation? = buffer.withUnsafeBytes { rawBuffer in
                let pixels = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
                if let current = geometry,
                   !analyzer.geometryStillValid(
                    current,
                    pixels: pixels,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow
                   ) {
                    geometry = nil
                    gate.reset()
                }
                if geometry == nil {
                    geometry = analyzer.locateGame(
                        pixels: pixels,
                        width: width,
                        height: height,
                        bytesPerRow: bytesPerRow
                    )
                }
                return geometry.map {
                    analyzer.observe(
                        geometry: $0,
                        pixels: pixels,
                        width: width,
                        height: height,
                        bytesPerRow: bytesPerRow
                    )
                }
            }

            let timestamp = timestampFromFilename(path) ?? Double(analyzedFrames) / 120.0
            guard let observation else {
                previousObservation = nil
                previousTimestamp = nil
                continue
            }
            analyzedFrames += 1
            if observation.feedbackChoice != nil {
                feedbackFrames += 1
            }

            // 화면 녹화 파일은 변화가 없는 구간을 가변 프레임으로 저장한다.
            // 실제 SCStream은 그 구간에도 idle 프레임을 주므로 120Hz 반복 프레임을 보충한다.
            if let previousObservation, let previousTimestamp {
                var idleTimestamp = previousTimestamp + 1.0 / 120.0
                while idleTimestamp + 0.000_001 < timestamp {
                    if let choice = gate.update(with: previousObservation, at: idleTimestamp) {
                        inputs.append((String(format: "idle-%06dms", Int(idleTimestamp * 1_000)), choice))
                    }
                    idleTimestamp += 1.0 / 120.0
                }
            }
            if let choice = gate.update(with: observation, at: timestamp) {
                inputs.append((URL(fileURLWithPath: path).lastPathComponent, choice))
            }
            previousObservation = observation
            previousTimestamp = timestamp
        }

        let expected: [GameChoice] = [.food, .food, .water, .water, .water, .food, .food]
        let actual = inputs.map(\.1)
        if actual == expected {
            print(
                "PASS  녹화 전체 \(analyzedFrames)프레임(지연 120ms): " +
                "반응 \(feedbackFrames)프레임, 입력 \(actual.map(\.rawValue).joined(separator: " → "))"
            )
            for (filename, choice) in inputs {
                print("      \(filename): \(choice.rawValue) 1회")
            }
            return 0
        }

        print("FAIL  녹화 전체 입력: 예상 \(expected.map(\.rawValue)), 실제 \(actual.map(\.rawValue))")
        return 1
    }

    private static func loadImage(path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func timestampFromFilename(_ path: String) -> TimeInterval? {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        guard let start = filename.range(of: "frame-")?.upperBound,
              let end = filename.range(of: "ms", range: start..<filename.endIndex)?.lowerBound,
              let milliseconds = Double(filename[start..<end]) else { return nil }
        return milliseconds / 1_000.0
    }
}

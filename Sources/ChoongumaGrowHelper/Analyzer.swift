import Foundation

enum GameChoice: String {
    case food = "음식"
    case water = "물"
}

struct PixelRect {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var midX: Double { Double(x) + Double(width) / 2.0 }
    var midY: Double { Double(y) + Double(height) / 2.0 }
}

struct GameGeometry {
    let yellowButton: PixelRect
    let cyanButton: PixelRect
    let centerX: Double
    let buttonCenterY: Double
    let scale: Double
}

struct FrameObservation {
    let choice: GameChoice?
    let feedbackChoice: GameChoice?
    let whiteScore: Double
    let grayScore: Double
    let orangeFeedbackScore: Double
    let cyanFeedbackScore: Double
}

private struct ColorComponent {
    let color: UInt8
    let count: Int
    let rect: PixelRect
}

final class FrameAnalyzer {
    private let referenceButtonWidth = 230.0

    func locateGame(
        pixels: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> GameGeometry? {
        let scanStep = max(3, min(6, max(width, height) / 500))
        let gridWidth = (width + scanStep - 1) / scanStep
        let gridHeight = (height + scanStep - 1) / scanStep
        guard gridWidth > 0, gridHeight > 0 else { return nil }

        var mask = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        for gridY in 0..<gridHeight {
            let y = min(height - 1, gridY * scanStep)
            for gridX in 0..<gridWidth {
                let x = min(width - 1, gridX * scanStep)
                let (r, g, b) = rgb(pixels, x: x, y: y, bytesPerRow: bytesPerRow)
                let index = gridY * gridWidth + gridX
                if isYellow(r: r, g: g, b: b) {
                    mask[index] = 1
                } else if isCyan(r: r, g: g, b: b) {
                    mask[index] = 2
                }
            }
        }

        var components: [ColorComponent] = []
        components.reserveCapacity(16)

        for start in 0..<mask.count {
            let color = mask[start]
            guard color != 0 else { continue }

            var queue: [Int] = [start]
            queue.reserveCapacity(2048)
            mask[start] = 0
            var cursor = 0
            var minX = start % gridWidth
            var maxX = minX
            var minY = start / gridWidth
            var maxY = minY

            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % gridWidth
                let y = index / gridWidth
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)

                if x > 0 {
                    consume(index - 1, color: color, mask: &mask, queue: &queue)
                }
                if x + 1 < gridWidth {
                    consume(index + 1, color: color, mask: &mask, queue: &queue)
                }
                if y > 0 {
                    consume(index - gridWidth, color: color, mask: &mask, queue: &queue)
                }
                if y + 1 < gridHeight {
                    consume(index + gridWidth, color: color, mask: &mask, queue: &queue)
                }
            }

            guard queue.count >= 50 else { continue }
            let rect = PixelRect(
                x: minX * scanStep,
                y: minY * scanStep,
                width: min(width - minX * scanStep, (maxX - minX + 1) * scanStep),
                height: min(height - minY * scanStep, (maxY - minY + 1) * scanStep)
            )
            components.append(ColorComponent(color: color, count: queue.count, rect: rect))
        }

        let yellow = components.filter { $0.color == 1 }.sorted { $0.count > $1.count }.prefix(8)
        let cyan = components.filter { $0.color == 2 }.sorted { $0.count > $1.count }.prefix(8)

        var bestPair: (ColorComponent, ColorComponent)?
        var bestScore = -Double.infinity

        for left in yellow {
            for right in cyan {
                let leftRect = left.rect
                let rightRect = right.rect
                guard leftRect.midX < rightRect.midX else { continue }

                let averageWidth = (Double(leftRect.width) + Double(rightRect.width)) / 2.0
                let averageHeight = (Double(leftRect.height) + Double(rightRect.height)) / 2.0
                guard averageWidth >= 70, averageHeight >= 45 else { continue }

                let widthRatio = Double(max(leftRect.width, rightRect.width)) /
                    Double(max(1, min(leftRect.width, rightRect.width)))
                let heightRatio = Double(max(leftRect.height, rightRect.height)) /
                    Double(max(1, min(leftRect.height, rightRect.height)))
                guard widthRatio < 1.35, heightRatio < 1.40 else { continue }

                let deltaX = rightRect.midX - leftRect.midX
                let deltaY = abs(rightRect.midY - leftRect.midY)
                guard deltaX > averageWidth * 0.82, deltaX < averageWidth * 1.75 else { continue }
                guard deltaY < max(14.0, averageHeight * 0.22) else { continue }

                let areaScore = Double(left.count + right.count)
                let alignmentPenalty = deltaY * 8.0
                let spacingPenalty = abs(deltaX / averageWidth - 1.22) * 300.0
                let score = areaScore - alignmentPenalty - spacingPenalty
                if score > bestScore {
                    bestScore = score
                    bestPair = (left, right)
                }
            }
        }

        guard let pair = bestPair else { return nil }
        let averageWidth = (Double(pair.0.rect.width) + Double(pair.1.rect.width)) / 2.0
        let scale = averageWidth / referenceButtonWidth
        guard scale >= 0.35, scale <= 4.0 else { return nil }

        return GameGeometry(
            yellowButton: pair.0.rect,
            cyanButton: pair.1.rect,
            centerX: (pair.0.rect.midX + pair.1.rect.midX) / 2.0,
            buttonCenterY: (pair.0.rect.midY + pair.1.rect.midY) / 2.0,
            scale: scale
        )
    }

    func geometryStillValid(
        _ geometry: GameGeometry,
        pixels: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> Bool {
        colorCoverage(
            rect: geometry.yellowButton,
            expected: 1,
            pixels: pixels,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        ) > 0.20 && colorCoverage(
            rect: geometry.cyanButton,
            expected: 2,
            pixels: pixels,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        ) > 0.20
    }

    func observe(
        geometry: GameGeometry,
        pixels: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> FrameObservation {
        let scale = geometry.scale
        let sampleStep = max(1, Int((2.0 * scale).rounded()))
        var whiteCounts = [0, 0]
        var grayCounts = [0, 0]
        var orangeFeedbackCount = 0
        var cyanFeedbackCount = 0

        let sideRanges: [(Double, Double)] = [(-310, -130), (130, 310)]
        let yStart = geometry.buttonCenterY - 680 * scale
        let yEnd = geometry.buttonCenterY - 400 * scale

        for (sideIndex, range) in sideRanges.enumerated() {
            let xStart = geometry.centerX + range.0 * scale
            let xEnd = geometry.centerX + range.1 * scale
            let minX = clamp(Int(xStart.rounded(.down)), lower: 0, upper: width)
            let maxX = clamp(Int(xEnd.rounded(.up)), lower: 0, upper: width)
            let minY = clamp(Int(yStart.rounded(.down)), lower: 0, upper: height)
            let maxY = clamp(Int(yEnd.rounded(.up)), lower: 0, upper: height)

            guard minX < maxX, minY < maxY else { continue }
            var y = minY
            while y < maxY {
                var x = minX
                while x < maxX {
                    let (r, g, b) = rgb(pixels, x: x, y: y, bytesPerRow: bytesPerRow)
                    let maximum = max(r, max(g, b))
                    let minimum = min(r, min(g, b))
                    let chroma = maximum - minimum
                    if minimum > 235 && chroma < 18 {
                        whiteCounts[sideIndex] += 1
                    }
                    if minimum > 145 && maximum < 238 && chroma < 25 {
                        grayCounts[sideIndex] += 1
                    }
                    x += sampleStep
                }
                y += sampleStep
            }
        }

        let normalization = Double(sampleStep * sampleStep) / max(0.01, scale * scale)
        let normalizedWhite = whiteCounts.map { Double($0) * normalization }
        let normalizedGray = grayCounts.map { Double($0) * normalization }
        let whiteScore = normalizedWhite.reduce(0, +)
        let grayScore = normalizedGray.reduce(0, +)

        // 반응 애니메이션의 고유 색을 버튼과 점수 영역을 제외한 양손 쪽에서 찾는다.
        // 음식: 주황색 음식, 물: 컵 안의 진한 하늘색 물.
        let feedbackSideRanges: [(Double, Double)] = [(-340, -80), (80, 340)]
        let feedbackYStart = geometry.buttonCenterY - 760 * scale
        let feedbackYEnd = geometry.buttonCenterY - 300 * scale
        for range in feedbackSideRanges {
            let minX = clamp(
                Int((geometry.centerX + range.0 * scale).rounded(.down)),
                lower: 0,
                upper: width
            )
            let maxX = clamp(
                Int((geometry.centerX + range.1 * scale).rounded(.up)),
                lower: 0,
                upper: width
            )
            let minY = clamp(Int(feedbackYStart.rounded(.down)), lower: 0, upper: height)
            let maxY = clamp(Int(feedbackYEnd.rounded(.up)), lower: 0, upper: height)
            guard minX < maxX, minY < maxY else { continue }

            var y = minY
            while y < maxY {
                var x = minX
                while x < maxX {
                    let (r8, g8, b8) = rgb(pixels, x: x, y: y, bytesPerRow: bytesPerRow)
                    let r = Int(r8)
                    let g = Int(g8)
                    let b = Int(b8)
                    if r >= 165, g >= 50, g <= 210, b <= 170,
                       r >= g + 20, g >= b + 5 {
                        orangeFeedbackCount += 1
                    }
                    if r <= 135, g >= 105, b >= 155,
                       b >= g + 8, g >= r + 25 {
                        cyanFeedbackCount += 1
                    }
                    x += sampleStep
                }
                y += sampleStep
            }
        }

        let orangeFeedbackScore = Double(orangeFeedbackCount) * normalization
        let cyanFeedbackScore = Double(cyanFeedbackCount) * normalization
        let feedbackChoice: GameChoice?
        if orangeFeedbackScore >= 200 {
            feedbackChoice = .food
        } else if cyanFeedbackScore >= 200 {
            feedbackChoice = .water
        } else {
            feedbackChoice = nil
        }

        let choice: GameChoice?
        if feedbackChoice != nil {
            // 반응 중에는 식기나 컵 외곽선이 남아 있어도 준비 상태가 아니다.
            choice = nil
        } else if whiteScore >= 1_000 {
            choice = .water
        } else if whiteScore < 650 && grayScore >= 600 {
            choice = .food
        } else {
            choice = nil
        }

        return FrameObservation(
            choice: choice,
            feedbackChoice: feedbackChoice,
            whiteScore: whiteScore,
            grayScore: grayScore,
            orangeFeedbackScore: orangeFeedbackScore,
            cyanFeedbackScore: cyanFeedbackScore
        )
    }

    private func colorCoverage(
        rect: PixelRect,
        expected: UInt8,
        pixels: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> Double {
        let step = max(3, min(rect.width, rect.height) / 18)
        let minX = clamp(rect.x, lower: 0, upper: width)
        let maxX = clamp(rect.x + rect.width, lower: 0, upper: width)
        let minY = clamp(rect.y, lower: 0, upper: height)
        let maxY = clamp(rect.y + rect.height, lower: 0, upper: height)
        guard minX < maxX, minY < maxY else { return 0 }

        var total = 0
        var matches = 0
        var y = minY
        while y < maxY {
            var x = minX
            while x < maxX {
                let (r, g, b) = rgb(pixels, x: x, y: y, bytesPerRow: bytesPerRow)
                total += 1
                if expected == 1 ? isYellow(r: r, g: g, b: b) : isCyan(r: r, g: g, b: b) {
                    matches += 1
                }
                x += step
            }
            y += step
        }
        return total == 0 ? 0 : Double(matches) / Double(total)
    }

    private func consume(_ index: Int, color: UInt8, mask: inout [UInt8], queue: inout [Int]) {
        if mask[index] == color {
            mask[index] = 0
            queue.append(index)
        }
    }

    private func rgb(
        _ pixels: UnsafePointer<UInt8>,
        x: Int,
        y: Int,
        bytesPerRow: Int
    ) -> (UInt8, UInt8, UInt8) {
        let offset = y * bytesPerRow + x * 4
        return (pixels[offset + 2], pixels[offset + 1], pixels[offset])
    }

    private func isYellow(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        r >= 225 && g >= 190 && g <= 248 && b >= 35 && b <= 145 && r > g
    }

    private func isCyan(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        r >= 155 && r <= 225 && g >= 200 && g <= 248 && b >= 225 && b >= g
    }

    private func clamp(_ value: Int, lower: Int, upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}

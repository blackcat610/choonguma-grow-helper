import Foundation

/// 입력 한 번과 다음 입력 사이에 반드시 게임의 색 반응이 한 번 지나가게 한다.
struct InputGate {
    private(set) var isWaitingForFeedback = false
    private(set) var sawExpectedFeedback = false

    private var expectedFeedback: GameChoice?
    private var expectedWhiteScore = 0.0
    private var expectedGrayScore = 0.0
    private var structuralFeedbackFrames = 0
    private var readyCandidate: GameChoice?
    private var readyFrames = 0
    private var readyStartedAt: TimeInterval?
    private let requiredReadyFrames: Int
    private let inputDelay: TimeInterval

    init(requiredReadyFrames: Int, inputDelay: TimeInterval = 0) {
        self.requiredReadyFrames = max(1, requiredReadyFrames)
        self.inputDelay = max(0, inputDelay)
    }

    mutating func update(
        with observation: FrameObservation,
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> GameChoice? {
        let explicitFeedback = observation.feedbackChoice == expectedFeedback &&
            observation.feedbackChoice != nil
        let structuralFeedback = isStructuralFeedback(observation)

        if isWaitingForFeedback, explicitFeedback {
            clearReadyCandidate()
            sawExpectedFeedback = true
            structuralFeedbackFrames = 0
            return nil
        }

        // 실시간 캡처의 색 공간이 녹화 JPEG와 달라도 동작하도록 형태 변화도 함께 본다.
        // 빈 컵의 흰색이나 식기의 회색이 크게 줄어든 프레임이 2장 이어지면
        // 반응 애니메이션으로 인정한다.
        if isWaitingForFeedback, structuralFeedback {
            clearReadyCandidate()
            if !sawExpectedFeedback {
                structuralFeedbackFrames += 1
                if structuralFeedbackFrames >= 2 {
                    sawExpectedFeedback = true
                }
            }
            return nil
        }

        if observation.feedbackChoice != nil {
            clearReadyCandidate()
            structuralFeedbackFrames = 0
            return nil
        }

        // 같은 준비 화면이 몇 프레임 계속 보여도 반응 화면을 보지 못한 상태에서는
        // 두 번째 키를 보내지 않는다. 이것이 연타를 막는 핵심 불변 조건이다.
        if isWaitingForFeedback, !sawExpectedFeedback {
            clearReadyCandidate()
            structuralFeedbackFrames = 0
            return nil
        }

        guard let choice = observation.choice else {
            clearReadyCandidate()
            return nil
        }

        if readyCandidate == choice {
            readyFrames += 1
        } else {
            readyCandidate = choice
            readyFrames = 1
            readyStartedAt = timestamp
        }

        guard readyFrames >= requiredReadyFrames else { return nil }
        guard let readyStartedAt,
              timestamp - readyStartedAt + 0.000_001 >= inputDelay else { return nil }

        isWaitingForFeedback = true
        sawExpectedFeedback = false
        expectedFeedback = choice
        expectedWhiteScore = observation.whiteScore
        expectedGrayScore = observation.grayScore
        structuralFeedbackFrames = 0
        clearReadyCandidate()
        return choice
    }

    mutating func reset() {
        isWaitingForFeedback = false
        sawExpectedFeedback = false
        expectedFeedback = nil
        expectedWhiteScore = 0
        expectedGrayScore = 0
        structuralFeedbackFrames = 0
        clearReadyCandidate()
    }

    private func isStructuralFeedback(_ observation: FrameObservation) -> Bool {
        guard isWaitingForFeedback, let expectedFeedback else { return false }
        if let readyChoice = observation.choice, readyChoice != expectedFeedback {
            return false
        }
        switch expectedFeedback {
        case .food:
            return expectedGrayScore >= 800 &&
                observation.grayScore <= expectedGrayScore * 0.86
        case .water:
            return expectedWhiteScore >= 1_500 &&
                observation.whiteScore <= expectedWhiteScore * 0.70
        }
    }

    private mutating func clearReadyCandidate() {
        readyCandidate = nil
        readyFrames = 0
        readyStartedAt = nil
    }
}

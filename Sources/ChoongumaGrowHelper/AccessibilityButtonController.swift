import ApplicationServices

final class AccessibilityButtonController {
    private let application: AXUIElement
    private var cachedButtons: [GameChoice: AXUIElement] = [:]
    private var cachedGameWindow: AXUIElement?

    init(processID: pid_t) {
        application = AXUIElementCreateApplication(processID)
    }

    @discardableResult
    func prepare() -> Bool {
        if cachedButtons[.food] != nil, cachedButtons[.water] != nil {
            return true
        }
        refreshButtons()
        return cachedButtons[.food] != nil && cachedButtons[.water] != nil
    }

    func press(_ choice: GameChoice) -> Bool {
        if let cached = cachedButtons[choice], performPress(on: cached) {
            return true
        }
        cachedButtons[choice] = nil

        refreshButtons()
        guard let button = cachedButtons[choice] else {
            return false
        }
        guard performPress(on: button) else { return false }
        cachedButtons[choice] = button
        return true
    }

    func pressReplay() -> Bool {
        for forceRefresh in [false, true] {
            guard let window = gameWindow(forceRefresh: forceRefresh) else { continue }
            guard let button = bestPressableButton(
                titled: "게임 다시하기",
                in: window
            ) else { continue }
            guard performPress(on: button) else { continue }
            cachedButtons.removeAll(keepingCapacity: true)
            NSLog("[ChoongumaGrowHelper] pressed replay button with AXPress")
            return true
        }
        return false
    }

    private func performPress(on element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private func refreshButtons() {
        let startedAt = CFAbsoluteTimeGetCurrent()
        for forceRefresh in [false, true] {
            cachedButtons.removeAll(keepingCapacity: true)
            guard let window = gameWindow(forceRefresh: forceRefresh) else { continue }
            collectButtons(in: window)
            if cachedButtons[.food] != nil, cachedButtons[.water] != nil {
                let elapsedMS = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
                NSLog(
                    "[ChoongumaGrowHelper] cached AXPress buttons in %.1fms",
                    elapsedMS
                )
                return
            }
        }
    }

    private func gameWindow(forceRefresh: Bool) -> AXUIElement? {
        if !forceRefresh,
           let cachedGameWindow,
           gameWindowScore(cachedGameWindow) > 0 {
            return cachedGameWindow
        }
        guard let windows = attribute(
            application,
            kAXWindowsAttribute as CFString
        ) as? [AXUIElement],
              let best = windows.max(by: { gameWindowScore($0) < gameWindowScore($1) }),
              gameWindowScore(best) > 0 else {
            cachedGameWindow = nil
            return nil
        }
        cachedGameWindow = best
        return best
    }

    private func collectButtons(in window: AXUIElement) {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var cursor = 0
        var visited = Set<CFHashCode>()
        var best: [GameChoice: (element: AXUIElement, area: CGFloat)] = [:]

        while cursor < queue.count, cursor < 2_000 {
            let (element, depth) = queue[cursor]
            cursor += 1
            guard visited.insert(CFHash(element)).inserted else { continue }

            let title = stringAttribute(element, kAXTitleAttribute as CFString)
            let choice: GameChoice?
            if title == "밥 주기" {
                choice = .food
            } else if title == "물 주기" {
                choice = .water
            } else {
                choice = nil
            }
            if let choice,
               supportsPress(element),
               let size = sizeAttribute(element),
               size.width >= 20,
               size.height >= 20 {
                let area = size.width * size.height
                if best[choice] == nil || area > best[choice]!.area {
                    best[choice] = (element, area)
                }
            }

            if depth < 40,
               let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        for (choice, match) in best {
            cachedButtons[choice] = match.element
        }
    }

    private func bestPressableButton(
        titled targetTitle: String,
        in window: AXUIElement
    ) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var cursor = 0
        var visited = Set<CFHashCode>()
        var best: (element: AXUIElement, area: CGFloat)?

        while cursor < queue.count, cursor < 2_000 {
            let (element, depth) = queue[cursor]
            cursor += 1
            guard visited.insert(CFHash(element)).inserted else { continue }

            if stringAttribute(element, kAXTitleAttribute as CFString) == targetTitle,
               supportsPress(element),
               let size = sizeAttribute(element),
               size.width >= 20,
               size.height >= 20 {
                let area = size.width * size.height
                if best == nil || area > best!.area {
                    best = (element, area)
                }
            }

            if depth < 40,
               let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return best?.element
    }

    private func gameWindowScore(_ window: AXUIElement) -> Double {
        guard let size = sizeAttribute(window), size.height > 0 else {
            return -Double.infinity
        }
        let ratio = Double(size.width / size.height)
        var score = -abs(ratio - 0.656) * 1_000
        if size.width >= 350, size.width <= 500,
           size.height >= 550, size.height <= 750 {
            score += 10_000
        }
        return score
    }

    private func supportsPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let actions = names as? [String] else { return false }
        return actions.contains(kAXPressAction as String)
    }

    private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String {
        attribute(element, name) as? String ?? ""
    }

    private func sizeAttribute(_ element: AXUIElement) -> CGSize? {
        guard let value = attribute(element, kAXSizeAttribute as CFString),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value
    }
}

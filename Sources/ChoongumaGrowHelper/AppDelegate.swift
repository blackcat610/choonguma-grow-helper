import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = CaptureEngine()
    private let keyBindings: [KeyBinding] = [
        KeyBinding(title: "← 왼쪽 화살표", keyCode: 123),
        KeyBinding(title: "→ 오른쪽 화살표", keyCode: 124),
        KeyBinding(title: "A", keyCode: 0),
        KeyBinding(title: "D", keyCode: 2),
        KeyBinding(title: "F", keyCode: 3),
        KeyBinding(title: "J", keyCode: 38),
        KeyBinding(title: "1", keyCode: 18),
        KeyBinding(title: "2", keyCode: 19),
        KeyBinding(title: "스페이스", keyCode: 49)
    ]
    private let readyFrameOptions: [(String, Int)] = [
        ("최고속 · 1프레임", 1),
        ("권장 · 2프레임", 2),
        ("안정 · 3프레임", 3)
    ]
    private let inputDelayOptions: [(String, TimeInterval)] = [
        ("없음 · 0ms", 0),
        ("60ms", 0.060),
        ("90ms", 0.090),
        ("기본 · 120ms", 0.120),
        ("150ms", 0.150),
        ("180ms", 0.180),
        ("240ms", 0.240),
        ("300ms", 0.300),
        ("400ms", 0.400),
        ("500ms", 0.500)
    ]

    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var startButton: NSButton!
    private var foodPopup: NSPopUpButton!
    private var waterPopup: NSPopUpButton!
    private var readyFramePopup: NSPopUpButton!
    private var inputDelayPopup: NSPopUpButton!
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()
        buildStatusItem()
        buildWindow()
        connectEngine()
        installHotkeyMonitors()
        showPanel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        engine.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func toggleAutomation() {
        if engine.isRunning {
            engine.stop()
            showPanel()
        } else {
            startAutomation()
        }
    }

    @objc private func showPanel() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    @objc private func openPrivacySettings() {
        let anchor = CGPreflightScreenCaptureAccess()
            ? "Privacy_Accessibility"
            : "Privacy_ScreenCapture"
        let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        )!
        NSWorkspace.shared.open(settingsURL)
    }

    @objc private func selectionChanged() {
        let defaults = UserDefaults.standard
        defaults.set(foodPopup.indexOfSelectedItem, forKey: "foodKeyIndex")
        defaults.set(waterPopup.indexOfSelectedItem, forKey: "waterKeyIndex")
        defaults.set(readyFramePopup.indexOfSelectedItem, forKey: "readyFrameIndex")
        defaults.set(inputDelayPopup.indexOfSelectedItem, forKey: "inputDelayIndex")
    }

    private func startAutomation() {
        let foodIndex = foodPopup.indexOfSelectedItem
        let waterIndex = waterPopup.indexOfSelectedItem
        let readyFrameIndex = readyFramePopup.indexOfSelectedItem
        let inputDelayIndex = inputDelayPopup.indexOfSelectedItem
        guard keyBindings.indices.contains(foodIndex),
              keyBindings.indices.contains(waterIndex),
              readyFrameOptions.indices.contains(readyFrameIndex),
              inputDelayOptions.indices.contains(inputDelayIndex) else { return }

        guard keyBindings[foodIndex].keyCode != keyBindings[waterIndex].keyCode else {
            updateStatus("키 설정을 확인하세요", detail: "음식과 물은 서로 다른 키여야 합니다.")
            return
        }

        guard screenCapturePermissionGranted() else { return }
        guard accessibilityPermissionGranted() else { return }

        engine.start(
            foodKey: keyBindings[foodIndex].keyCode,
            waterKey: keyBindings[waterIndex].keyCode,
            requiredReadyFrames: readyFrameOptions[readyFrameIndex].1,
            inputDelay: inputDelayOptions[inputDelayIndex].1
        )
    }

    private func screenCapturePermissionGranted() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        if CGRequestScreenCaptureAccess() {
            return true
        }
        updateStatus(
            "화면 기록 권한이 필요합니다",
            detail: "시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록에서 허용한 뒤 앱을 다시 실행하세요."
        )
        return false
    }

    private func accessibilityPermissionGranted() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            return true
        }
        updateStatus(
            "손쉬운 사용 권한이 필요합니다",
            detail: "시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 이 앱을 허용한 뒤 다시 시작을 누르세요."
        )
        return false
    }

    private func connectEngine() {
        engine.onStatus = { [weak self] text in
            self?.updateStatus(text, detail: self?.detailForStatus(text) ?? "")
        }
        engine.onRunningChanged = { [weak self] running in
            guard let self else { return }
            self.startButton.title = running ? "정지" : "시작"
            self.toggleMenuItem.title = running ? "자동 입력 정지 (F8)" : "자동 입력 시작 (F8)"
            self.statusItem.button?.contentTintColor = running ? .systemGreen : .secondaryLabelColor
            if running {
                NSApp.hide(nil)
            } else if self.window.isVisible == false {
                self.showPanel()
            }
        }
        engine.onInput = { [weak self] choice, count, whiteScore, grayScore in
            guard let self else { return }
            let keyTitle: String
            if choice == .food {
                keyTitle = self.keyBindings[self.foodPopup.indexOfSelectedItem].title
            } else {
                keyTitle = self.keyBindings[self.waterPopup.indexOfSelectedItem].title
            }
            self.updateStatus(
                "자동 입력 중 · \(count)회",
                detail: "최근 인식: \(choice.rawValue) → \(keyTitle)  (판별값 \(Int(whiteScore))/\(Int(grayScore)))"
            )
        }
    }

    private func installHotkeyMonitors() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 100, !event.isARepeat else { return }
            DispatchQueue.main.async { self?.toggleAutomation() }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 100, !event.isARepeat else { return event }
            self?.toggleAutomation()
            return nil
        }
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "춘구마 키우기 도우미 정보", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "종료", action: #selector(quitApplication), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "cup.and.saucer.fill",
            accessibilityDescription: "춘구마 키우기 도우미"
        )
        statusItem.button?.contentTintColor = .secondaryLabelColor

        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "정지됨", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        toggleMenuItem = NSMenuItem(title: "자동 입력 시작 (F8)", action: #selector(toggleAutomation), keyEquivalent: "")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)
        let showItem = NSMenuItem(title: "설정 보기", action: #selector(showPanel), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "종료", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 486),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "춘구마 키우기 도우미"
        window.center()
        window.isReleasedWhenClosed = false

        let content = NSView()
        window.contentView = content

        let title = label("춘구마 키우기 도우미", size: 26, weight: .bold)
        let subtitle = label(
            "캐릭터 손의 컵 또는 식기를 인식해 키를 누릅니다.",
            size: 13,
            color: .secondaryLabelColor
        )

        statusLabel = label("정지됨", size: 17, weight: .semibold)
        statusLabel.alignment = .center
        detailLabel = label(
            "게임을 시작한 뒤 F8을 누르거나 아래 시작 버튼을 누르세요.",
            size: 12,
            color: .secondaryLabelColor
        )
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byWordWrapping

        let statusBox = NSBox()
        statusBox.boxType = .custom
        statusBox.borderWidth = 0
        statusBox.fillColor = NSColor.controlBackgroundColor
        statusBox.cornerRadius = 12
        statusBox.contentViewMargins = NSSize(width: 14, height: 12)
        let statusStack = NSStackView(views: [statusLabel, detailLabel])
        statusStack.orientation = .vertical
        statusStack.spacing = 6
        statusStack.alignment = .centerX
        statusBox.contentView = statusStack

        foodPopup = popup(keyBindings.map(\.title))
        waterPopup = popup(keyBindings.map(\.title))
        readyFramePopup = popup(readyFrameOptions.map(\.0))
        inputDelayPopup = popup(inputDelayOptions.map(\.0))

        let defaults = UserDefaults.standard
        foodPopup.selectItem(at: validIndex(defaults.object(forKey: "foodKeyIndex") as? Int ?? 0, count: keyBindings.count))
        waterPopup.selectItem(at: validIndex(defaults.object(forKey: "waterKeyIndex") as? Int ?? 1, count: keyBindings.count))
        readyFramePopup.selectItem(at: validIndex(defaults.object(forKey: "readyFrameIndex") as? Int ?? 0, count: readyFrameOptions.count))
        inputDelayPopup.selectItem(at: validIndex(defaults.object(forKey: "inputDelayIndex") as? Int ?? 3, count: inputDelayOptions.count))

        let foodRow = settingsRow(title: "음식 (숟가락·포크)", control: foodPopup)
        let waterRow = settingsRow(title: "물 (컵)", control: waterPopup)
        let speedRow = settingsRow(title: "준비 자세 확인", control: readyFramePopup)
        let delayRow = settingsRow(title: "입력 전 지연", control: inputDelayPopup)

        startButton = NSButton(title: "시작", target: self, action: #selector(toggleAutomation))
        startButton.bezelStyle = .rounded
        startButton.controlSize = .large
        startButton.keyEquivalent = "\r"

        let privacyButton = NSButton(title: "권한 설정 열기", target: self, action: #selector(openPrivacySettings))
        privacyButton.bezelStyle = .inline
        privacyButton.font = NSFont.systemFont(ofSize: 12)

        let note = label(
            "준비 자세가 유지되면 설정한 지연 후 한 번만 입력합니다.\n실행 중 F8: 즉시 정지/재시작",
            size: 11,
            color: .tertiaryLabelColor
        )
        note.maximumNumberOfLines = 3
        note.lineBreakMode = .byWordWrapping
        note.alignment = .center

        let stack = NSStackView(views: [
            title, subtitle, statusBox, foodRow, waterRow, speedRow, delayRow,
            startButton, privacyButton, note
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(18, after: subtitle)
        stack.setCustomSpacing(18, after: statusBox)
        stack.setCustomSpacing(6, after: foodRow)
        stack.setCustomSpacing(6, after: waterRow)
        stack.setCustomSpacing(6, after: speedRow)
        stack.setCustomSpacing(18, after: delayRow)
        stack.setCustomSpacing(8, after: startButton)
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            statusBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
            foodRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            waterRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            speedRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            delayRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            startButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            startButton.heightAnchor.constraint(equalToConstant: 38)
        ])
    }

    private func settingsRow(title: String, control: NSView) -> NSStackView {
        let titleLabel = label(title, size: 13, weight: .medium)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.widthAnchor.constraint(equalToConstant: 175).isActive = true
        let row = NSStackView(views: [titleLabel, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        return row
    }

    private func popup(_ titles: [String]) -> NSPopUpButton {
        let result = NSPopUpButton()
        result.addItems(withTitles: titles)
        result.target = self
        result.action = #selector(selectionChanged)
        return result
    }

    private func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let result = NSTextField(labelWithString: text)
        result.font = NSFont.systemFont(ofSize: size, weight: weight)
        result.textColor = color
        return result
    }

    private func validIndex(_ index: Int, count: Int) -> Int {
        max(0, min(index, count - 1))
    }

    private func updateStatus(_ status: String, detail: String) {
        statusLabel.stringValue = status
        detailLabel.stringValue = detail
        statusMenuItem.title = status
    }

    private func detailForStatus(_ status: String) -> String {
        if status.contains("찾는 중") {
            return "미니게임을 화면에 보이게 두세요. 시작 화면에서는 입력하지 않습니다."
        }
        if status.contains("첫 문제") {
            return "컵과 식기 판별이 안정되면 자동 입력을 시작합니다."
        }
        if status.contains("실패") || status.contains("중단") {
            return "권한을 확인한 뒤 다시 시도하세요."
        }
        if status == "정지됨" {
            return "게임을 시작한 뒤 F8을 누르거나 아래 시작 버튼을 누르세요."
        }
        return detailLabel?.stringValue ?? ""
    }
}

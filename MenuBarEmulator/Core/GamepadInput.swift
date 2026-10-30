import GameController
import Observation

/// Game controllers (Xbox, PlayStation, Switch Pro, MFi…) through Apple's GameController framework.
/// Buttons are positional, Nintendo style: the right face button is A, the bottom one is B.
@Observable
final class GamepadInput {
    enum Button: Hashable, CaseIterable {
        case up, down, left, right, a, b, x, y, l, r, l2, r2, start, select
        /// Home / stick clicks: open the in-game menu.
        case home, l3, r3
    }

    /// Names of connected controllers, for Settings.
    private(set) var connected: [String] = []
    @ObservationIgnored var onChange: ((Set<Button>) -> Void)?
    @ObservationIgnored var onConnect: ((String, Bool) -> Void)?

    init() {
        // The window never activates the app, so listen even while another app is frontmost.
        GCController.shouldMonitorBackgroundEvents = true
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.setUp(controller)
            self?.refresh()
            self?.onConnect?(controller.vendorName ?? "Controller", true)
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            self?.refresh()
            self?.onChange?([])
            self?.onConnect?((note.object as? GCController)?.vendorName ?? "Controller", false)
        }
        GCController.controllers().forEach(setUp)
        refresh()
    }

    private func refresh() {
        connected = GCController.controllers().filter { $0.extendedGamepad != nil }.map { $0.vendorName ?? "Controller" }
    }

    private func setUp(_ controller: GCController) {
        controller.handlerQueue = .main
        controller.extendedGamepad?.valueChangedHandler = { [weak self] pad, _ in
            self?.onChange?(Self.buttons(of: pad))
        }
    }

    static func buttons(of pad: GCExtendedGamepad) -> Set<Button> {
        var set = Set<Button>()
        let stick = pad.leftThumbstick
        if pad.dpad.up.isPressed || stick.yAxis.value > 0.5 { set.insert(.up) }
        if pad.dpad.down.isPressed || stick.yAxis.value < -0.5 { set.insert(.down) }
        if pad.dpad.left.isPressed || stick.xAxis.value < -0.5 { set.insert(.left) }
        if pad.dpad.right.isPressed || stick.xAxis.value > 0.5 { set.insert(.right) }
        if pad.buttonB.isPressed { set.insert(.a) }
        if pad.buttonA.isPressed { set.insert(.b) }
        if pad.buttonY.isPressed { set.insert(.x) }
        if pad.buttonX.isPressed { set.insert(.y) }
        if pad.leftShoulder.isPressed { set.insert(.l) }
        if pad.rightShoulder.isPressed { set.insert(.r) }
        if pad.leftTrigger.isPressed { set.insert(.l2) }
        if pad.rightTrigger.isPressed { set.insert(.r2) }
        if pad.buttonMenu.isPressed { set.insert(.start) }
        if pad.buttonOptions?.isPressed == true { set.insert(.select) }
        if pad.buttonHome?.isPressed == true { set.insert(.home) }
        if pad.leftThumbstickButton?.isPressed == true { set.insert(.l3) }
        if pad.rightThumbstickButton?.isPressed == true { set.insert(.r3) }
        return set
    }
}

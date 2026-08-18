import XCTest

extension XCUIElement {
    // waitForExistence re-evaluates on a fixed ~1s timer and waits for app
    // quiescence, which a SwiftUI app with a live spinner/animation never
    // reaches, so each call costs seconds even when the element is already
    // there. Poll the (instant) snapshot fast instead.
    func waitToAppear(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return exists
    }

    // A disabled placeholder can carry the same label as the control it stands in
    // for, so existence alone does not mean the control is the live one.
    func waitToEnable(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, isEnabled {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return exists && isEnabled
    }
}

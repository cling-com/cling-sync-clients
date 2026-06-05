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
}

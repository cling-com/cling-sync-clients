import Foundation

// A transient alert shown over the main screen. At most one is shown at a time,
// which makes the old `if errorMessage == nil` guards a type-level invariant.
// Passphrase and S3-credential prompts are NOT modelled here: on iOS they are
// continuation-driven sheets owned by their prompt controllers, resumed from the
// store. Connection failures are a full screen (`AppPhase.connectionFailed`), so
// the only overlay today is the error alert for scan/upload failures.
enum Overlay: Equatable {
    case none
    case error(title: String, message: String)
}

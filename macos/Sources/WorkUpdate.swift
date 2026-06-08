import Foundation

// A normalized poll/start signal. The store maps a bridge poll (via
// OperationState.from) into one of these so the reducer never sees the transport
// flag-structs. `absent` is the old "filtered out / empty row" case; the reducer
// keeps a terminal state on it (Bug B).
enum WorkUpdate: Equatable {
    case snapshot(OperationState)
    case absent
}

import Observation

/// The Search page retains its query and receives focus requests from tab reselection.
@MainActor @Observable
final class NSearchInput {
    var text = ""
    var focusRequest = 0
}

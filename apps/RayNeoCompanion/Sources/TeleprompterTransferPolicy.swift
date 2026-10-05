/// Coordinates the business prepare acknowledgement and the SDK file transfer.
/// Neither acknowledgement alone proves that the manuscript is ready to start.
/// A new value must be created for each manuscript transfer attempt.
struct TeleprompterTransferPolicy {
    enum Decision: Equatable {
        case startFile
        case wait
        case ready
        case reject
    }

    private(set) var fileRequestedBool = false
    private(set) var fileSubmittedBool = false
    private(set) var businessCompleteBool = false
    private(set) var fileCompleteBool = false
    private var rejected = false
    var isTerminal: Bool { rejected }

    init() {}

    mutating func prepareReply(code: Int) -> Decision {
        guard !rejected else { return .reject }
        switch code {
        case 1:
            // Firmware may repeat its request while the SDK is sending the file.
            // It is never a completion acknowledgement, including after readiness.
            guard !fileRequestedBool else { return .wait }
            fileRequestedBool = true
            return .startFile
        case 7:
            guard fileSubmittedBool else { return reject() }
            businessCompleteBool = true
            return completionDecision
        default:
            return reject()
        }
    }

    /// Call only after sendFile has returned successfully. SDK completion may
    /// already have arrived synchronously; it cannot make this attempt ready
    /// before submission is committed here.
    mutating func fileSubmissionSucceeded() -> Decision {
        guard !rejected, fileRequestedBool else { return reject() }
        fileSubmittedBool = true
        return completionDecision
    }

    mutating func fileCompleted(success: Bool) -> Decision {
        guard !rejected, fileRequestedBool, success else { return reject() }
        fileCompleteBool = true
        return completionDecision
    }

    /// Ends this attempt when submission throws, the connection disappears, or
    /// the user cancels. Delayed callbacks cannot revive the cancelled attempt.
    mutating func cancel() {
        rejected = true
    }

    private var completionDecision: Decision {
        fileSubmittedBool && businessCompleteBool && fileCompleteBool ? .ready : .wait
    }

    private mutating func reject() -> Decision {
        rejected = true
        return .reject
    }
}

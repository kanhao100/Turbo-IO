// DECLARATION-ONLY research module for the exact v1.2.35 binary. Emit a
// .swiftmodule ONLY; never compile/link these placeholder class definitions.
// Original class objects come exclusively from the signed SDK. No constructors
// or properties are exposed here because their full resilient ABI is unknown.
import Foundation
public final class RNCoreConnect { private init() {} }
public final class RNDevice { private init() {} }
public final class RNMessage { private init() {} }

// Original descriptor 0x184ecc: class-bound, five requirements in this order.
// The generated conformance references the ORIGINAL RayneoNet protocol symbol,
// unlike a same-shaped protocol declared in the application module.
public protocol RNMessageDelegate: AnyObject {
    func message(_ core: RNCoreConnect, receive: RNMessage)
    func message(_ core: RNCoreConnect, deviceListChanged: [RNDevice], _ reason: String)
    func message(_ core: RNCoreConnect, sendSuccess: RNMessage)
    func message(_ core: RNCoreConnect, sendError: RNMessage, _ code: Int, _ reason: String)
    func messageDecryptFail(_ core: RNCoreConnect, device: RNDevice,
                            sourceData: Data, sourceLen: Int, destLen: Int)
}

// Exact v1.2.35 enum field metadata: sender/receiver are no-payload byte tags;
// the error has one String payload and three no-payload cases. Declaration-only:
// emit the module, never link replacement implementations into the application.
public enum RNShareRole {
    case sender
    case receiver
}

public enum RNFileShareError {
    case otherError(errorDes: String)
    case localNetworkUnauthorized
    case bleUnavailable
    case apUnavailable
}

// Original protocol descriptor 0x184a40. Native callback witness loads at
// 0x5d160/0x5d210/0x5d2d4/0x5d3d0 establish this requirement order (+8/+16/+24/+32).
public protocol RNFileShareDelegate: AnyObject {
    func fileShare(_ core: RNCoreConnect, device: RNDevice,
                   role: RNShareRole, startShare: String)
    func fileShare(_ core: RNCoreConnect, device: RNDevice,
                   progressChange: Int, taskId: String, chunkData: Data)
    func fileShare(_ core: RNCoreConnect, device: RNDevice,
                   role: RNShareRole, success: String, fileName: String, fileUrl: URL)
    func fileShare(_ core: RNCoreConnect, device: RNDevice,
                   role: RNShareRole, failed: String, error: RNFileShareError)
}

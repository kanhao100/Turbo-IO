import Foundation
import RayneoNet

extension CoreHandle {
    @_silgen_name("$s9RayneoNet13RNCoreConnectC3add17fileShareDelegateyAA06RNFilegH0_p_tF")
    func addFileShareDelegate(_ delegate: any RNFileShareDelegate)
    @_silgen_name("$s9RayneoNet13RNCoreConnectC6remove17fileShareDelegateyAA06RNFilegH0_p_tF")
    func removeFileShareDelegate(_ delegate: any RNFileShareDelegate)
}

/// The pinned SDK's own file callbacks. No chunk data, local URL or original
/// error description is forwarded. Consumers correlate native task IDs with
/// their own file submission; a returned task ID alone is not delivery proof.
final class CoreFileShareReceiver: RNFileShareDelegate {
    // Stages: 0 started, 1 progress, 2 completed, 3 failed.
    var onEvent: ((String, String, Int, Int?, String?, String?) -> Void)?

    private func emit(device: RNDevice, task: String, stage: Int,
                      progress: Int? = nil, fileName: String? = nil,
                      errorCode: String? = nil) {
        guard !task.isEmpty, task.utf8.count <= 256,
              fileName.map({ $0.utf8.count <= 1024 }) ?? true else { return }
        let handle = unsafeBitCast(device, to: DeviceHandle.self)
        let id = handle.deviceID()
        guard !id.isEmpty, id.utf8.count <= 256 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(id, task, stage, progress, fileName, errorCode)
        }
    }

    func fileShare(_ core: RNCoreConnect, device: RNDevice,
                   role: RNShareRole, startShare: String) {
        guard case .sender = role else { return }
        emit(device: device, task: startShare, stage: 0)
    }

    func fileShare(_ core: RNCoreConnect, device: RNDevice,
                   progressChange: Int, taskId: String, chunkData: Data) {
        // This native callback has no role parameter. The consumer must match
        // its owned sender task before using the progress value.
        emit(device: device, task: taskId, stage: 1, progress: progressChange)
    }

    func fileShare(_ core: RNCoreConnect, device: RNDevice,
                   role: RNShareRole, success: String, fileName: String, fileUrl: URL) {
        guard case .sender = role else { return }
        emit(device: device, task: success, stage: 2, fileName: fileName)
    }

    func fileShare(_ core: RNCoreConnect, device: RNDevice,
                   role: RNShareRole, failed: String, error: RNFileShareError) {
        guard case .sender = role else { return }
        let code: String
        switch error {
        case .localNetworkUnauthorized: code = "localNetworkUnauthorized"
        case .bleUnavailable: code = "bleUnavailable"
        case .apUnavailable: code = "apUnavailable"
        case .otherError: code = "other"
        }
        emit(device: device, task: failed, stage: 3, errorCode: code)
    }
}

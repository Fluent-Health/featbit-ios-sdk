import Foundation

/// A no-op synchronizer used in offline mode; always reports as initialized.
final class NullDataSynchronizer: DataSynchronizer {
    let initialized = true
    func start() async -> Bool { true }
    func close() {}
}

import Foundation

// Shared by the Mac and iPhone apps.

enum ViewMode: Int {
    case split = 0, before, after
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

func scaleText(_ s: Double) -> String {
    let r = (s * 100).rounded() / 100
    return (r == r.rounded() ? String(Int(r)) : String(r)) + "×"
}

/// Prints to Terminal when Texel is started from there; harmless otherwise.
enum Diag {
    static func log(_ s: String) {
        FileHandle.standardError.write(("[Texel] " + s + "\n").data(using: .utf8)!)
    }
}

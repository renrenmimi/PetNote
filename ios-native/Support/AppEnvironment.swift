import Foundation

/// Which backend this build talks to, and how to reach it.
///
/// Read once from the bundle, which gets its values from the xcconfig for the
/// active configuration. There is deliberately no runtime switch and no `if`
/// on environment anywhere else: the Capacitor client's compile-time
/// VITE_PASSWORD_RESET_OTP taught us that a flag you cannot flip without a new
/// build is a flag you will forget is off — but the fix for that is
/// server-delivered config, not a code branch that could point a debug build
/// at production data by accident.
struct AppEnvironment: Sendable {
    enum Backend: String, Sendable {
        case emulator
        case production
    }

    let backend: Backend
    /// The Mac's LAN address when running against the emulator. A device cannot
    /// reach 127.0.0.1, which is why this is configured rather than assumed.
    let emulatorHost: String
    let buildStamp: String

    static let current = AppEnvironment(bundle: .main)

    init(bundle: Bundle) {
        let info = bundle.infoDictionary
        let raw = info?["PetNoteBackend"] as? String ?? ""
        backend = Backend(rawValue: raw) ?? .emulator
        emulatorHost = (info?["PetNoteEmulatorHost"] as? String) ?? "127.0.0.1"
        buildStamp = (info?["PetNoteBuildStamp"] as? String) ?? "unknown"
    }

    /// Stage 1 writes only to the emulator. Production configurations are
    /// read-only, and this is what the repositories check before a write.
    var allowsWrites: Bool { backend == .emulator }

    var firestoreHost: String { "\(emulatorHost):8088" }
    var authHost: String { "\(emulatorHost):9099" }
    var functionsHost: String { emulatorHost }
    var functionsPort: Int { 5101 }
}

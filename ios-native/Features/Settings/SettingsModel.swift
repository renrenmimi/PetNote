import FirebaseFirestore
import Foundation
import Observation
import OSLog

/// The three notification switches of the web client's Settings, stored where
/// it stores them: `users/{uid}/settings/preferences`, one boolean each, true
/// when absent (`src/services/settings.ts:21-26`, and the server reads a
/// missing key the same way, `functions/src/notifications.ts:173-177`).
struct NotificationPreferences: Equatable, Sendable {
    var likes = true
    var comments = true
    var follows = true

    enum Key: String, CaseIterable, Sendable {
        case likes = "likeNotifications"
        case comments = "commentNotifications"
        case follows = "followNotifications"
    }

    subscript(key: Key) -> Bool {
        get {
            switch key {
            case .likes: likes
            case .comments: comments
            case .follows: follows
            }
        }
        set {
            switch key {
            case .likes: likes = newValue
            case .comments: comments = newValue
            case .follows: follows = newValue
            }
        }
    }

    /// Reads a stored document, keeping the default for anything missing or
    /// not a boolean.
    init(stored: [String: Any]? = nil) {
        for key in Key.allCases {
            if let value = stored?[key.rawValue] as? Bool { self[key] = value }
        }
    }
}

protocol PreferencesStoring: Sendable {
    func preferences(uid: String) async throws -> NotificationPreferences
    /// Writes one switch, merged, as the web does — the rules accept only the
    /// known keys on this document (`firestore.rules`, settingsKeysOk).
    func set(_ key: NotificationPreferences.Key, to value: Bool, uid: String) async throws
}

struct FirestorePreferencesStore: PreferencesStoring {
    private func reference(_ uid: String) -> DocumentReference {
        Firestore.firestore().collection("users").document(uid).collection("settings").document("preferences")
    }

    func preferences(uid: String) async throws -> NotificationPreferences {
        NotificationPreferences(stored: try await reference(uid).getDocument().data())
    }

    func set(_ key: NotificationPreferences.Key, to value: Bool, uid: String) async throws {
        try await reference(uid).setData([key.rawValue: value], merge: true)
    }
}

@MainActor
@Observable
final class SettingsModel {
    enum PreferencesState: Equatable {
        case loading
        case loaded
        case failed
    }

    private(set) var preferences = NotificationPreferences()
    private(set) var preferencesState: PreferencesState = .loading
    /// Per switch: a write on its way. The switch is not touchable meanwhile.
    private(set) var saving: Set<NotificationPreferences.Key> = []
    /// The last switch that could not be saved; it has been put back.
    private(set) var saveFailure: String?
    /// Whether the account can sign in with a password — only then is there
    /// a password to change (the web offered the row to every account, and a
    /// Google-only one could only ever be told "current password is incorrect").
    private(set) var hasPassword = false
    private(set) var hasGoogle = false
    /// A deletion that started and did not finish.
    private(set) var deletionPending = false

    let uid: String
    private let store: any PreferencesStoring
    private let security: any AccountSecurity
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "settings")

    init(uid: String, store: any PreferencesStoring, security: any AccountSecurity) {
        self.uid = uid
        self.store = store
        self.security = security
    }

    func load() async {
        let methods = await security.signInMethods()
        hasPassword = methods.contains("password")
        hasGoogle = methods.contains("google.com")
        deletionPending = await security.deletionPending(uid: uid) ?? deletionPending
        do {
            preferences = try await store.preferences(uid: uid)
            preferencesState = .loaded
        } catch {
            log.error("preferences read failed: \(String(describing: error), privacy: .public)")
            if preferencesState != .loaded { preferencesState = .failed }
        }
    }

    /// Changes a switch at once and writes it; puts it back if the write is
    /// refused — the web's optimistic toggle with a per-key rollback.
    func set(_ key: NotificationPreferences.Key, to value: Bool) async {
        guard preferencesState == .loaded, !saving.contains(key), preferences[key] != value else { return }
        let before = preferences[key]
        preferences[key] = value
        saving.insert(key)
        saveFailure = nil
        defer { saving.remove(key) }
        do {
            try await store.set(key, to: value, uid: uid)
        } catch {
            log.error("preference write failed: \(String(describing: error), privacy: .public)")
            preferences[key] = before
            saveFailure = String(localized: "Failed to save settings.")
        }
    }
}

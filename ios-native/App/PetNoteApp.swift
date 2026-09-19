import SwiftUI

/// Entry point. Deployment target is iOS 18.0 — every API used here has been
/// available since iOS 17 or earlier unless a comment says otherwise.
@main
struct PetNoteApp: App {
    @State private var session = SessionStore()

    init() {
        // Before any Firestore or Functions instance exists: emulator settings
        // are ignored once the first request has gone out.
        FirebaseBootstrap.configure()
        ImageLoader.shared.observeMemoryWarnings()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .task { session.start() }
        }
    }
}

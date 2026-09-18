import SwiftUI

/// Entry point. Deployment target is iOS 18.0 — every API used here is
/// available since iOS 17 or earlier unless a comment says otherwise.
@main
struct PetNoteApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

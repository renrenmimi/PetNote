import GoogleSignIn
import SwiftUI

/// Entry point. Deployment target is iOS 18.0 — every API used here has been
/// available since iOS 17 or earlier unless a comment says otherwise.
@main
struct PetNoteApp: App {
    @State private var session = SessionStore()

    init() {
        #if DEBUG
        // A UI test's tidy-up, for the one thing a test cannot reach from
        // outside the app: what the app wrote into its own defaults.
        // `FeedExtrasUITests` opens a spotlight tile as a throwaway account,
        // which leaves that account's seen list behind, and its tearDown
        // relaunches with this flag and the account's uid. Debug-only and
        // argument-gated, like `-petnote-start-signed-out`; nothing in the
        // app passes it.
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-petnote-forget-seen-spotlights"),
           arguments.indices.contains(flag + 1) {
            UserDefaultsSpotlightSeenStore().clear(uid: arguments[flag + 1])
        }
        #endif
        // Before any Firestore or Functions instance exists: emulator settings
        // are ignored once the first request has gone out.
        FirebaseBootstrap.configure()
        if FirebaseBootstrap.isConfiguredForRunning {
            ImageLoader.shared.observeMemoryWarnings()
        }
    }

    var body: some Scene {
        WindowGroup {
            // Unit tests are hosted inside this app but are pure logic over
            // fakes — none of them touch Firebase or a session. Starting the
            // real app for them means configuring Firebase against an emulator
            // that is not running, and on CI that took the test runner down
            // with a SIGTRAP before a single test executed.
            //
            // UI tests are unaffected: they launch this app as its own process,
            // which has no XCTest configuration in its environment.
            if FirebaseBootstrap.isConfiguredForRunning {
                RootView()
                    .environment(session)
                    .task { session.start() }
                    // Google's page hands the result back through a URL; any
                    // other is a PetNote link (`petnote://post/<id>`), which
                    // opens what it names once someone is signed in.
                    .onOpenURL { url in
                        if GIDSignIn.sharedInstance.handle(url) { return }
                        session.openLink(url)
                    }
            } else {
                Color.clear.accessibilityIdentifier("app.unitTestHost")
            }
        }
    }
}

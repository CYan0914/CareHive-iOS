// Entry point.
//
// There is no debug banner, no "demo mode" ribbon and no environment selector
// on screen, and that is on purpose. The screenshot pipeline photographs this
// app on a CI runner; anything that renders only in a debug build ends up in a
// submitted screenshot, and a review team that sees "DEMO" in a screenshot sees
// a build that is not the one they will get. The demo is selected at launch and
// then entirely invisible.

import SwiftUI

@main
struct CareHiveApp: App {
    /// Built once per launch from the launch arguments. `AppEnvironment` decides
    /// whether it is the live server or the stub.
    private let api: any CareHiveAPI = AppEnvironment.makeAPI()

    var body: some Scene {
        WindowGroup {
            // Portrait-only is enforced by `UISupportedInterfaceOrientations` in
            // Info.plist, which is the mechanism that actually works for a
            // SwiftUI app with no scene delegate. There is deliberately no
            // SwiftUI-side lock here: one would be a no-op that reads like a
            // guarantee.
            RootGate(api: api, demoScreen: AppEnvironment.demoScreen)
        }
    }
}

/// Decides whether this launch starts at the door or inside the app.
///
/// Kept out of `RootView` so that the screen picker stays a pure switch over
/// launch arguments. A sign-in gate folded into it would mean a capture job
/// with no session rendering the sign-in screen for every screenshot -- and
/// the failure would look like "the demo is broken" rather than "the gate is
/// in the way". A demo launch therefore skips the gate entirely, which is
/// honest: there is no session behind `DemoAPI` to check.
struct RootGate: View {
    let api: any CareHiveAPI
    let demoScreen: String?

    @State private var token: String? = SessionStore.shared.token

    var body: some View {
        if demoScreen != nil || token != nil {
            RootView(api: api, demoScreen: demoScreen)
        } else {
            SignInView(api: api) { signedIn in
                // The one place a credential is written. Deliberately in the
                // view rather than in the client, so that a sign-in which
                // fails halfway cannot leave a stored token behind -- see the
                // note on `SignedIn`.
                SessionStore.shared.token = signedIn.sessionToken
                token = signedIn.sessionToken
            }
        }
    }
}

/// Picks the screen. In a normal launch this is just the app; with
/// `-CareHiveDemo <screen>` it opens straight onto a named screen so the capture
/// script can photograph it without driving any UI.
struct RootView: View {
    let api: any CareHiveAPI
    let demoScreen: String?

    var body: some View {
        switch demoScreen {
        case "race":
            // The two-sibling race. Rendered directly because reaching it
            // through the UI needs a second phone recording the same dose at the
            // same moment, which is not something a capture job can arrange.
            DemoRaceScreen()
        case "record":
            DemoRecordScreen(api: api)
        case "meds":
            DemoMedsScreen(api: api)
        case "supply":
            DemoSupplyScreen(api: api)
        case "history":
            DemoHistoryScreen(api: api)
        case "circle":
            DemoCircleScreen(api: api)
        case "displays":
            DemoDisplaysScreen(api: api)
        case "settings":
            DemoSettingsScreen(api: api)
        case "paywall":
            PaywallView(api: api)
        case "wall":
            // The tablet's own screen, on the tablet. Same binary, different
            // credential -- see `WallView`.
            WallRootView()
        case "signin":
            SignInView(api: api) { _ in }
        default:
            DemoAppTabs(api: api)
        }
    }
}

// MARK: - The app, as the capture job sees it

/// The real navigation, with the real screens, so a screenshot of "settings"
/// is a screenshot of the app's settings rather than of a test harness.
private struct DemoAppTabs: View {
    let api: any CareHiveAPI

    var body: some View {
        TabView {
            NavigationStack { TodayView(api: api) }
                .tabItem { Label("Today", systemImage: "calendar") }
            NavigationStack {
                MedicationListView(api: api, recipientId: "rc_demo_margaret", canEdit: true)
            }
            .tabItem { Label("Medications", systemImage: "pills") }
            NavigationStack {
                HistoryView(api: api, recipientId: "rc_demo_margaret")
            }
            .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            NavigationStack { SettingsView(api: api) }
                .tabItem { Label("You", systemImage: "person.crop.circle") }
        }
    }
}

/// The screens below are reached directly rather than by tapping through, for
/// the same reason the other demo screens exist: the capture job launches
/// straight onto the screen it is photographing, and driving a tab bar from a
/// shell script is a second thing that can break.
private struct DemoMedsScreen: View {
    let api: any CareHiveAPI

    var body: some View {
        NavigationStack {
            MedicationListView(api: api, recipientId: "rc_demo_margaret", canEdit: true)
        }
    }
}

private struct DemoSupplyScreen: View {
    let api: any CareHiveAPI

    var body: some View {
        NavigationStack {
            SupplyView(api: api, recipientId: "rc_demo_margaret")
        }
    }
}

private struct DemoHistoryScreen: View {
    let api: any CareHiveAPI

    var body: some View {
        NavigationStack {
            HistoryView(api: api, recipientId: "rc_demo_margaret")
        }
    }
}

private struct DemoCircleScreen: View {
    let api: any CareHiveAPI

    var body: some View {
        NavigationStack {
            CircleView(api: api, recipientId: "rc_demo_margaret")
        }
    }
}

private struct DemoDisplaysScreen: View {
    let api: any CareHiveAPI

    var body: some View {
        NavigationStack {
            DisplaysView(api: api, recipientId: "rc_demo_margaret")
        }
    }
}

private struct DemoSettingsScreen: View {
    let api: any CareHiveAPI

    var body: some View {
        NavigationStack { SettingsView(api: api) }
    }
}

// MARK: - Screens the capture job launches directly

private struct DemoRaceScreen: View {
    @State private var show = true

    var body: some View {
        ZStack {
            TodayView(api: DemoAPI()).opacity(0.35).blur(radius: 1)
            if show {
                AlreadyGivenView(
                    given: AlreadyGiven(
                        givenByName: "David Whitfield",
                        givenAt: "2026-01-01 12:06:00",
                        givenAtLocal: "\(todayLocal()) 12:06",
                        administrationId: "ad_demo_race",
                        dose: nil),
                    onDismiss: { show = false })
                .transition(.opacity)
            }
        }
    }

    private func todayLocal() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
    }
}

/// Opens the day with the record sheet already up, for the screenshot that
/// shows what happens after the tap.
private struct DemoRecordScreen: View {
    let api: any CareHiveAPI

    var body: some View {
        TodayView(api: api, openDoseIndex: 2)
    }
}

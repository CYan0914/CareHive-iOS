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
            RootView(api: api, demoScreen: AppEnvironment.demoScreen)
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
        default:
            TodayView(api: api)
        }
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

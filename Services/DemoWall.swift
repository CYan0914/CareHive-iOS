// The wall, as the screenshot job sees it.
//
// A peer of `DemoAPI`, and for the same reason: the capture runner has no
// backend, no paired tablet and no way to conjure one, so the one screen that
// exists to be looked at from across a room has to be renderable from a launch
// argument. Everything here is derived from the same seeded day the phone's
// demo shows, so a screenshot of the tablet and a screenshot of the phone do
// not disagree about what happened this morning.

import Foundation

actor DemoWallAPI: KitchenWallAPI {
    private let recipient = WallRecipient(
        id: "rc_demo_margaret", name: "Margaret Whitfield",
        callName: "Margaret", timezone: "America/New_York")

    private var display: DisplayDevice {
        DisplayDevice(id: "dp_demo_kitchen", recipientId: recipient.id,
                      label: "Kitchen iPad", paired: true,
                      pairedAt: DemoAPI.day(-21) + " 18:40:00",
                      lastSeenAt: DemoAPI.day(0) + " 08:05:00",
                      revokedAt: nil,
                      tokenExpiresAt: DemoAPI.day(60) + " 18:40:00",
                      createdAt: DemoAPI.day(-21) + " 18:32:00")
    }

    func whoAmI() async throws -> WallWhoAmI {
        WallWhoAmI(display: display, recipient: recipient,
                   now: DemoAPI.day(0) + " 08:05:00",
                   largeText: true, canRecord: false)
    }

    func today() async throws -> WallToday {
        // Three recorded, one still due, out of four. Chosen because the middle
        // of a day is the state a caregiver actually opens this screen to check,
        // and because "3 of 4" is legible at a glance from across a kitchen.
        //
        // Every `*Local` here is a full timestamp, in the exact shape the
        // server sends -- `due_at_local` is "2026-09-25 08:00", not a bare
        // clock. A demo that supplied "08:00" would render an empty time on
        // the wall and look like a formatting bug in `WallClock`, which reads
        // a bare clock as a slot time and refuses a short string on purpose.
        let doses: [WallDose] = [
            WallDose(id: "dose_demo_1", timeLocal: today(8, 0), slotLabel: "Morning",
                     medicationName: "Donepezil", medicationStrength: "10 mg",
                     unitsPerDose: 1, unitLabel: "tablet", status: .given,
                     givenAtLocal: today(8, 6),
                     givenByName: "Sarah Whitfield"),
            WallDose(id: "dose_demo_2", timeLocal: today(8, 0), slotLabel: "Morning",
                     medicationName: "Metformin", medicationStrength: "500 mg",
                     unitsPerDose: 1, unitLabel: "tablet", status: .given,
                     givenAtLocal: today(8, 7),
                     givenByName: "Sarah Whitfield"),
            WallDose(id: "dose_demo_3", timeLocal: today(8, 0), slotLabel: "Morning",
                     medicationName: "Prednisone", medicationStrength: "5 mg",
                     unitsPerDose: 1, unitLabel: "tablet", status: .given,
                     givenAtLocal: today(8, 7),
                     givenByName: "Sarah Whitfield"),
            WallDose(id: "dose_demo_4", timeLocal: today(20, 0), slotLabel: "Evening",
                     medicationName: "Donepezil", medicationStrength: "10 mg",
                     unitsPerDose: 1, unitLabel: "tablet", status: .pending,
                     givenAtLocal: nil, givenByName: nil),
        ]
        let prn: [WallPRN] = [
            WallPRN(id: "prn_demo_1", timeLocal: today(6, 40),
                    medicationName: "Tylenol", units: 2, unitLabel: "tablet",
                    givenByName: "David Whitfield"),
        ]
        return WallToday(display: display, recipient: recipient,
                         date: DemoAPI.day(0), isToday: true,
                         now: DemoAPI.day(0) + " 08:05:00",
                         // A bare "%H:%M", which is what the server's
                         // `now_local` is -- the single field on this payload
                         // that is not a full timestamp.
                         nowLocal: "08:05",
                         doses: doses, prnToday: prn,
                         counts: WallCounts(total: doses.count,
                                            given: doses.filter { $0.status == .given }.count,
                                            pending: doses.filter { $0.status == .pending }.count),
                         beyondHorizon: false, canRecord: false)
    }

    /// The recipient's local wall-clock stamp for a time today. Matches
    /// `due_at_local`, which is minutes-resolution with no seconds.
    private func today(_ hour: Int, _ minute: Int) -> String {
        String(format: "%@ %02d:%02d", DemoAPI.day(0), hour, minute)
    }
}

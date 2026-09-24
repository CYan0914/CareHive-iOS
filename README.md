# CareHive iOS

A shared record of whether an elderly parent's medication has been given, for
the family members who take turns giving it.

The product exists for one sentence: **"Mum had her pill — Sarah gave it at
9:04."** That is the whole thing. The pain it addresses is not that families
fail to write things down; it is that two siblings cannot see each other's
record, so one of them drives over at 9pm to check, or a dose gets given twice.

## What this app does not do

These are product boundaries, not current limitations, and they should not be
relaxed by a later feature request without the user deciding to change the
product:

- It never recommends a dose, and never calculates one.
- It never checks anything against anything — no interactions, no intervals.
- It never says a duplicate dose was "prevented". It says one was already
  recorded, by whom, and when.
- It never alerts on a reading or a pattern in the log.

CareHive records and reports. It does not instruct. Both the API and the app
copy are written to hold that line, and the button labels are where it is
easiest to lose: the app's verb is **Record**, never **Give**.

## Layout

| Path | What is in it |
|---|---|
| `project.yml` | The build definition. `xcodegen generate` writes `CareHive.xcodeproj` from this, and the `.xcodeproj` is deliberately not committed. |
| `Resources/Info.plist` | Every Info.plist entry. The build settings in `project.yml` carry no `INFOPLIST_KEY_*` for a reason explained there. |
| `Models/Wire.swift` | The API's shapes, mirrored. |
| `Core/WallClock.swift` | The rule that the recipient's local clock is the only clock the UI shows. |
| `Core/DesignSystem.swift` | Colours, spacing, and the state vocabulary. |
| `Core/AppEnvironment.swift` | Which server to talk to, and which screen to open on. |
| `Services/APIClient.swift` | The live client, including how the duplicate-dose race is modelled. |
| `Services/DemoAPI.swift` | A stub peer of the live client, so screenshots and UI work need no server. |
| `Views/` | The screens. |
| `Tests/` | The pure logic that fails silently. |

## The two things that are easy to get wrong

**Time.** A `*_local` string from the API is a *label on the recipient's wall
clock*, not an instant. `WallClock` parses it into numbers by hand and formats
those numbers. It deliberately never builds a `Date` from one, because a `Date`
is an instant and invites exactly the timezone conversion that must not happen.
A shared codebase that shows 8am to a daughter in Chicago as 7am has broken the
only feature it has.

**The race.** If two people record the same dose at the same moment, one wins.
The loser must be told who won and when — not shown an error, and above all not
invited to record it again. The `409` is modelled as a *value*
(`GiveOutcome.someoneElseGotThere`) rather than a thrown error, so the handling
lives in one place instead of at every call site.

## Running it

```
xcodegen generate
xcodebuild test -scheme CareHive -destination 'platform=iOS Simulator,name=iPhone 16'
```

With no backend running, launch with `-CareHiveDemo today` (or `record`, or
`race`) to run against the stub. CI uses the same switch to photograph screens
without a server.

## Backend

The API lives in a sibling repo, `carehive-api` (FastAPI + SQLite, on a
Tencent Cloud Lighthouse host). It is the authority on schedules,
materialization, and authorisation; this app renders what it is told.

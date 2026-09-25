#!/bin/bash
#
# App Store screenshots for CareHive.
#
# Ported from the pipeline in `AppStore截图流水线提示词.md`, minus everything
# that was specific to Expo: there is no Metro, no prebuild and no `__DEV__`,
# so the parts that existed to wait for a bundler or to hide a dev-only ribbon
# have nothing to do here. What is kept is the set of rules that were learned
# the hard way and are not tool-specific:
#
#   * the pixel size is dictated by the App Store Connect slot, not by whatever
#     device the runner happens to have
#   * a screenshot is taken only once two consecutive frames are identical --
#     a fixed sleep photographs a spinner and reports success
#   * `simctl install` before `launch`, or launch fails with `code=4` and the
#     error looks exactly like "the app is missing"
#   * the size is asserted in the script, because App Store Connect infers the
#     slot from the pixels and says so only at upload time
#
# The demo mode is built into the app rather than bolted on for CI: launching
# with `-CareHiveDemo <screen>` swaps in `DemoAPI` and opens straight onto that
# screen, so nothing here drives a UI. See `CareHiveApp.swift`.
set -euo pipefail

APP="${APP:-build/Build/Products/Debug-iphonesimulator/CareHive.app}"
OUT="${OUT:-shots}"

# The slots, not preferences. 1284x2778 is 6.5" and 2064x2752 is 13".
PHONE_W=1284; PHONE_H=2778
TABLET_W=2064; TABLET_H=2752

PHONE_SCREENS=(today race record meds supply circle history settings)
# The wall leads on iPad: it is the one screen that exists because of a tablet
# in a kitchen, and it is the screen a caregiver recognises from the listing.
TABLET_SCREENS=(wall today record meds)

[ -d "$APP" ] || { echo "::error::no .app at $APP"; exit 1; }

# Read from the product rather than hardcoded. A bundle id that disagrees with
# the built app makes `simctl launch` fail with `code=4`, which is the same
# error as never having installed it.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
echo "app:    $APP"
echo "bundle: $BUNDLE_ID"
echo

dims() {
  sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null \
    | awk '/pixelWidth:/{w=$2} /pixelHeight:/{h=$2} END{print w"x"h}'
}

pick() {
  # By name, not UDID: simulator identifiers are not stable across Xcode
  # versions, so one captured in an earlier run is a device that no longer
  # exists.
  xcrun simctl list devices available -j | jq -r --arg p "$1" '
    [ .devices | to_entries[] | select(.key | test("SimRuntime.iOS-")) ]
    | sort_by(.key) | reverse
    | [ .[].value[] | select(.name | test($p)) ][0].udid // empty'
}

# A device only if one is creatable. Apple removes device types from newer
# runtimes, so building a 6.5" iPhone works on some runners and not others --
# and when it does not, the runner's own devices are all 6.9", which is a
# different slot. Escalating to the newest iPhone and scaling is the documented
# fallback, and the scale factor is small enough to be invisible.
make_or_borrow_phone() {
  local rt udid out dt
  rt=$(xcrun simctl list runtimes -j \
        | jq -r '[.runtimes[] | select(.platform=="iOS" and .isAvailable)][0].identifier')
  for dt in iPhone-14-Plus iPhone-13-Pro-Max iPhone-12-Pro-Max iPhone-11-Pro-Max; do
    if out=$(xcrun simctl create "shots-$dt" \
               "com.apple.CoreSimulator.SimDeviceType.$dt" "$rt" 2>&1); then
      echo "$out"; return 0
    fi
    echo "  cannot create $dt" >&2
  done
  echo "  no 6.5\" device creatable -- borrowing the newest iPhone" >&2
  pick '^iPhone 1[6-9]' || pick '^iPhone'
}

make_or_borrow_tablet() {
  local udid
  udid=$(pick '^iPad Pro 13-inch') || true
  [ -n "$udid" ] || udid=$(pick '^iPad Pro 12\.9') || true
  [ -n "$udid" ] || udid=$(pick '^iPad')
  echo "$udid"
}

# Two identical frames in a row, or no picture. A spinner changes every frame,
# so a fixed sleep returns one and the job still goes green -- which is how a
# whole batch of loading screens once shipped.
wait_stable() {
  local udid="$1" out="$2" prev="" cur="" i
  for i in $(seq 1 45); do
    xcrun simctl io "$udid" screenshot "$out" >/dev/null 2>&1 || true
    cur=$(md5 -q "$out" 2>/dev/null || echo "")
    if [ -n "$prev" ] && [ "$cur" = "$prev" ]; then return 0; fi
    prev="$cur"
    sleep 2
  done
  return 1
}

# Always to the slot size, even when the capture was already right: `sips -z`
# is a no-op at the same size, and a capture path that sometimes scales and
# sometimes does not is one where the assertion below fails intermittently.
fit() {
  local src="$1" dst="$2" w="$3" h="$4"
  sips -z "$h" "$w" "$src" --out "$dst" >/dev/null
}

capture() {
  local udid="$1" dir="$2" kind="$3"; shift 3
  local screens=("$@")
  local w h
  if [ "$kind" = iphone ]; then w=$PHONE_W; h=$PHONE_H; else w=$TABLET_W; h=$TABLET_H; fi

  mkdir -p "$dir"
  xcrun simctl bootstatus "$udid" -b 2>/dev/null || echo "  note: bootstatus non-zero, continuing"

  xcrun simctl install "$udid" "$APP"      # before launch, always
  xcrun simctl status_bar "$udid" override \
    --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3

  # Warm launch, discarded. The first launch of a freshly installed app does
  # its first-run work while the screen is already up.
  xcrun simctl launch "$udid" "$BUNDLE_ID" -CareHiveDemo "${screens[0]}" >/dev/null 2>&1 || true
  wait_stable "$udid" /tmp/warm.png || echo "  note: warm-up never settled"
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true

  local screen raw d
  for screen in "${screens[@]}"; do
    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    if ! xcrun simctl launch "$udid" "$BUNDLE_ID" -CareHiveDemo "$screen" > /tmp/launch.log 2>&1; then
      echo "::error::launch failed screen=$screen"; cat /tmp/launch.log; exit 1
    fi
    raw="/tmp/raw-$kind-$screen.png"
    if ! wait_stable "$udid" "$raw"; then
      echo "::error::$screen never settled -- refusing to ship a spinner"; exit 1
    fi
    fit "$raw" "$dir/$screen.png" "$w" "$h"

    d=$(dims "$dir/$screen.png")
    if [ "$d" != "${w}x${h}" ]; then
      echo "::error::$dir/$screen.png is $d, expected ${w}x${h}"; exit 1
    fi
    echo "  ok $screen -> $d"
  done
}

PHONE=$(make_or_borrow_phone)
TABLET=$(make_or_borrow_tablet)
[ -n "$PHONE" ]  || { echo "::error::no iPhone simulator available";  exit 1; }
[ -n "$TABLET" ] || { echo "::error::no iPad simulator available";    exit 1; }
echo "phone:  $PHONE"
echo "tablet: $TABLET"
echo

capture "$PHONE"  "$OUT/iphone65" iphone "${PHONE_SCREENS[@]}"
capture "$TABLET" "$OUT/ipad13"   tablet "${TABLET_SCREENS[@]}"

# The subscription review screenshot, captured on its own rather than appended
# to PHONE_SCREENS.
#
# It is not a listing image. App Store Connect refuses to submit an app whose
# auto-renewable subscription is in MISSING_METADATA, and the only missing
# piece is this: a picture of the offer for the reviewer. Whether a paywall
# belongs in the storefront is a marketing decision, and quietly adding a
# ninth screenshot to the listing would be making it by accident.
#
# Renders without a price, because a simulator has no storefront -- the screen
# degrades to naming the plans rather than inventing a number, which is the
# behaviour `PaywallView.loadPrices()` was written for.
capture "$PHONE" "$OUT/subreview" iphone paywall

echo
echo "captured:"
find "$OUT" -name '*.png' | sort | while read -r f; do echo "  $(dims "$f")  $f"; done

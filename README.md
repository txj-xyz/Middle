# Middle

Middle mouse button for the MacBook trackpad — click, and press-and-hold to drag.
macOS has no built-in gesture for it, so Middle reads raw finger contacts from
the trackpad and synthesises the button itself.

It runs as a menu bar item with no Dock icon (`LSUIElement`), on macOS 13 or later.

## Build

```sh
./build.sh          # produces build/Middle.app
open build/Middle.app
```

On first launch macOS asks for two permissions. Both are required, and the menu
bar item shows which one it is still waiting for:

- **Accessibility** — create an event tap and post mouse events.
- **Input Monitoring** — read the raw trackpad contact stream.

Grant them in System Settings ▸ Privacy & Security; the app picks them up within
a couple of seconds, no relaunch needed.

## Gestures

Pick one in the menu bar or in Settings.

| Gesture | Click | Drag |
| --- | --- | --- |
| **Multi-finger tap** (default) | Tap with 3 (or 4) fingers | Rest the fingers until the button engages, then move them |
| **Multi-finger click** | Physically click with 3 (or 4) fingers down | Keep it clicked and move the fingers |
| **Bottom-centre click zone** | Physically click with one finger in the bottom-middle strip | Keep it clicked and move that finger |

Dragging is continuous: the button stays down as long as the gesture is held and
releases when you let go.

## How it works

Three stages, wired together in `AppDelegate`:

```
trackpad → MultitouchReader → GestureEngine → MiddleButton → macOS
              (raw frames)     (decides)      (posts events)
                                  ↑
                          EventTapController
                        (clicks and pointer motion)
```

**1. Read the trackpad.** `MultitouchReader` gets the finger contacts that macOS
does not otherwise expose. They come from MultitouchSupport, a private
framework, so it is resolved at runtime with `dlopen`/`dlsym` rather than linked
— if a future macOS drops it, the app says so in the menu bar instead of failing
to launch. Each frame (position, count, timing) becomes a `TouchFrame`, delivered
on the framework's own thread.

**2. Decide.** `GestureEngine` is the only place that decides to press or
release. For the default tap gesture, N fingers landing starts a candidate that
resolves three ways:

- lift quickly and still → **middle click**
- hold still past *Hold to start dragging after* → **press and hold**, and the
  fingers then drive the pointer until they lift
- move before either → **nothing happens**, and the swipe goes through to
  Mission Control as usual

Frames arrive on one thread and events on another, so every entry point takes the
same recursive lock.

**3. Synthesise.** `MiddleButton` posts the actual events. The awkward part is
motion: posting an `otherMouseDown` without a matching up does not tell macOS a
button is held, so it keeps emitting plain `mouseMoved` events and apps that
listen for middle-drag (Blender, CAD tools, Figma, terminal autoscroll) see
nothing. Every movement during a hold has to reach the system as
`otherMouseDragged`, by one of two paths:

- **Synthetic** — multi-finger gestures. macOS will not move the pointer while
  several fingers are planted, so the engine integrates the mean per-finger delta
  and moves the pointer itself, swallowing any motion events the system produces
  so the two do not fight.
- **Rewritten** — the single-finger click zone. macOS is already moving the
  pointer, so the event tap rewrites each move into a middle-drag in place.

`EventTapController` owns the `CGEventTap` that claims clicks and rewrites
motion. It runs on its own thread and run loop, because a tap that misses its
deadline behind a blocked UI gets disabled by the system. Events Middle creates
carry a magic stamp so the tap recognises its own output instead of reprocessing
it.

| File | Role |
| --- | --- |
| `Sources/CMultitouch/include/CMultitouch.h` | Layout of the private `MTTouch` contact struct |
| `MultitouchReader.swift` | dlopens MultitouchSupport, attaches to devices, decodes frames |
| `GestureEngine.swift` | Gesture state machine; the only place that decides to press or release |
| `MiddleButton.swift` | Event synthesis and pointer integration |
| `EventTapController.swift` | CGEventTap on its own thread: claims clicks, rewrites motion |
| `SystemGestureCoordinator.swift` | Suppresses and relocates the competing system gestures |
| `Preferences.swift` | Settings, stored in `com.joeyfinelli.middle` |
| `StatusItemController.swift` / `SettingsView.swift` | Menu bar and settings UI |

A middle button stuck down would be miserable, so a watchdog releases the button
if trackpad frames stop arriving mid-drag.

## Conflicts with built-in gestures

Mission Control and full-screen app switching are recognised inside WindowServer,
straight from the multitouch stream — they produce no swipe event for an app to
intercept. Middle works around that on two levels, both driven by the single
*Move Mission Control and app switching to four fingers* switch in Settings.

**Blocking** takes effect immediately: while one of our gestures is in progress,
Middle withholds the gesture event stream from everything downstream. It is
scoped to the gesture, so pinch and rotate behave normally the rest of the time.
A gesture arms only after the finger count has held for two consecutive frames,
so a four-finger swipe is not claimed on its way through a three-finger frame.

**Relocating** takes effect at your next login: Middle moves the competing
settings onto the finger count it is not using, so three-finger mode leaves
Mission Control and app switching on four fingers. These are the same preferences
the System Settings ▸ Trackpad checkboxes write, and WindowServer only re-reads
them at login — hence the two levels.

Everything is restored on quit, on switching Middle off, and on picking a
non-conflicting gesture. The previous values are stashed and flushed to disk
before anything is written, so a crash or a `kill -9` is recovered on the next
launch rather than leaving your trackpad changed.

## Settings and diagnostics

Settings has a live view of the trackpad surface showing each contact, which is
the easy way to size the bottom-centre zone and to confirm the trackpad is being
read at all. Gesture timings and *Drag speed* — how far a full-width finger sweep
moves the pointer — are adjustable there too. "Open at Login" registers the app
with `SMAppService`.

    Middle --diagnose            # print live trackpad contacts for 8s
    Middle --diagnose-conflict   # log event types and input notifications for 45s

Both are read-only; the conflict tap is listen-only and excludes keyboard events
from its mask entirely.

A few knobs have no UI and are set with `defaults write com.joeyfinelli.middle …`:
the three mechanisms behind the single Settings switch (`suppressSystemGestures`,
`manageSystemGestures`, `relocateSystemGestures`) stay individually settable for
debugging, and `restartDockOnChange -bool true` restores the Dock restart that is
otherwise off — it does not make WindowServer re-read the gesture settings, which
is why it was dropped from the UI.

## Releases

`.github/workflows/ci.yml` builds a universal `Middle.app` on every push and pull
request. `.github/workflows/release.yml` does the same on a `v*` tag and
publishes the zip to GitHub Releases:

```sh
git tag v1.2.3 && git push origin v1.2.3
```

The tag is the version — `v1.2.3` is stamped into `CFBundleShortVersionString`,
so nothing in `Info.plist` is edited by hand. Both workflows run `build.sh`,
which takes `UNIVERSAL=1`, `VERSION=` and `CODESIGN_IDENTITY=` from the
environment so CI and local builds stay the same script.

### Signing a release

macOS ties the Accessibility and Input Monitoring grants to the app's code
signature. An ad-hoc signature changes on every build, so the permissions have to
be re-approved each time; a real Developer ID identity keeps them stable, and
`build.sh` uses one from your keychain whenever it finds one.

With no secrets configured the released app is ad-hoc signed — it runs, but
Gatekeeper blocks it on download and the release notes say how to clear the
quarantine flag. Setting these repository secrets gets a Developer ID signature
and a notarised, stapled bundle instead:

| Secret | |
| --- | --- |
| `MACOS_CERT_P12` | Developer ID Application certificate and key, exported as .p12, base64-encoded |
| `MACOS_CERT_PASSWORD` | Password used for that export |
| `MACOS_SIGN_IDENTITY` | Identity to sign with, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `NOTARY_APPLE_ID` | Apple ID for notarisation |
| `NOTARY_TEAM_ID` | Ten-character team ID |
| `NOTARY_PASSWORD` | App-specific password, from appleid.apple.com |

The certificate is the first three, notarisation the last three. Either half
works on its own, and the workflow skips whichever it has no secrets for.

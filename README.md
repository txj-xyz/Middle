# Middle

Middle mouse button for the MacBook trackpad — click, and press-and-hold to drag.
macOS has no built-in gesture for it, so this reads raw finger contacts from the
trackpad and synthesises the button itself.

## Build

```sh
./build.sh          # produces build/Middle.app
open build/Middle.app
```

On first launch macOS will ask for two permissions. Both are required:

- **Accessibility** — create an event tap and post mouse events.
- **Input Monitoring** — read the raw trackpad contact stream.

Grant them in System Settings ▸ Privacy & Security, then the app picks them up
within a couple of seconds; no relaunch needed. The menu bar item shows what it
is waiting for.

## Gestures

Pick one in the menu bar or in Settings.

| Gesture | Click | Drag |
| --- | --- | --- |
| **Multi-finger tap** (default) | Tap with 3 (or 4) fingers | Rest the fingers until the button engages, then move them |
| **Multi-finger click** | Physically click with 3 (or 4) fingers down | Keep it clicked and move the fingers |
| **Bottom-centre click zone** | Physically click with one finger in the bottom-middle strip | Keep it clicked and move that finger |

Dragging is continuous: the button stays down as long as the gesture is held and
releases when you let go.

### Multi-finger tap, in detail

Placing N fingers on the pad starts a candidate gesture that resolves three ways:

- lift quickly and still → **middle click**
- hold still past *Hold to start dragging after* → **button presses and holds**,
  and the fingers then drive the pointer until they lift
- move before either of those → **nothing happens**, and the swipe goes through
  to Mission Control as usual

The timings are adjustable in Settings if swipes and taps are getting confused.

## Conflicts with built-in gestures

Mission Control and full-screen app switching are recognised inside WindowServer,
straight from the multitouch stream. A diagnostic run confirmed this: the gesture
produces no swipe event (type 31) anywhere in the session event stream, so there
is nothing an app can intercept at the obvious place. Middle works around it on
two levels.

**Blocking, which takes effect immediately.** While one of our gestures is
actually in progress, Middle withholds the gesture event stream (types 18, 19,
20, 29, 30, 31, 32) from everything downstream. That is enough to stop Mission
Control claiming the fingers, and it is scoped to the gesture, so pinch, rotate
and everything else behave normally the rest of the time. This is the mechanism
that makes three-finger drag usable.

A gesture arms only after the finger count has held for two consecutive frames,
and an aborted sequence stays aborted until every finger lifts. Fingers never
land together, so without both of those a four-finger swipe — which passes
through a three-finger frame on its way down — gets claimed and blocked.

**Relocating, which takes effect at your next login.** Middle also moves the
competing settings onto the finger count it is not using, so three-finger mode
leaves Mission Control and full-screen app switching on four fingers:

| While Middle runs (3-finger mode) | |
| --- | --- |
| Three-finger swipe up / left / right | off — Middle's |
| Four-finger swipe up / left / right | on — Mission Control, app switching |
| Three-finger tap and three-finger drag | off (tap gesture only) |

Selecting a four-finger gesture relocates in the other direction, and the
bottom-centre click zone relocates nothing at all. A gesture you had already
switched off stays off — Middle relocates what exists and never adds a gesture
you did not have.

Both levels are driven by the single *Move Mission Control and app switching to
four fingers* switch in Settings. The three mechanisms behind it
(`suppressSystemGestures`, `manageSystemGestures`, `relocateSystemGestures`) stay
individually settable with `defaults write com.joeyfinelli.middle …` for
debugging.

Everything is restored on quit. The previous values — including "this key did not
exist" — are stashed in Middle's own preferences before anything is written, and
flushed to disk immediately, so a crash or a `kill -9` is recovered on the next
launch rather than leaving your trackpad changed. Signal handlers cover `kill`,
and the settings are also handed back whenever you switch Middle off or pick a
non-conflicting gesture.

These preference writes are exactly what the System Settings ▸ Trackpad ▸ More
Gestures checkboxes write — there is no separate API for them. What System
Settings has and we do not is whatever makes WindowServer re-read them without a
login; restarting the Dock does not do it, because the Dock is not the process
deciding. Hence the two-level approach: blocking covers this session, relocating
makes the settings correct from your next login onward. Restarting the Dock on
each change is therefore off, and no longer offered in the UI; it survives as
`defaults write com.joeyfinelli.middle restartDockOnChange -bool true`.

### Diagnostics

    Middle --diagnose            # print live trackpad contacts for 8s
    Middle --diagnose-conflict   # log event types and input notifications for 45s

Both are read-only; the conflict tap is listen-only and excludes keyboard events
from its mask entirely.

## Tuning

Settings has a live view of the trackpad surface showing each contact, which is
the easy way to size the bottom-centre zone and to confirm the trackpad is being
read at all. `Middle --diagnose` prints the same data to a terminal for eight
seconds.

*Drag speed* is how many pixels a full-width finger sweep moves the pointer, for
the gestures where we drive the cursor ourselves.

## How it works

The awkward part of a synthetic middle button is motion. Posting an
`otherMouseDown` without a matching up does not tell macOS a button is held, so
it keeps emitting plain `mouseMoved` events and apps that listen for middle-drag
(Blender, CAD tools, Figma, terminal autoscroll) see nothing. Every movement
during a hold therefore has to reach the system as `otherMouseDragged`, by one
of two paths:

- **Synthetic** — multi-finger gestures. macOS will not move the pointer while
  several fingers are planted, so `GestureEngine` integrates the mean per-finger
  delta, moves the pointer itself, and swallows any motion events the system
  produces so the two do not fight.
- **Rewritten** — the single-finger click zone. macOS is already moving the
  pointer, so the event tap rewrites each move into a middle-drag in place.

| File | Role |
| --- | --- |
| `Sources/CMultitouch/include/CMultitouch.h` | Layout of the private `MTTouch` contact struct |
| `MultitouchReader.swift` | dlopens MultitouchSupport, attaches to devices, decodes frames |
| `GestureEngine.swift` | Gesture state machine; the only place that decides to press or release |
| `MiddleButton.swift` | Event synthesis and pointer integration |
| `EventTapController.swift` | CGEventTap on its own thread: claims clicks, rewrites motion |
| `StatusItemController.swift` / `SettingsView.swift` | Menu bar and settings UI |

MultitouchSupport is a private framework, so it is resolved at runtime rather
than linked: if a future macOS drops it, the app reports the problem in the menu
bar instead of failing to launch. The struct layout it hands back is validated
per frame, and a mismatch is logged once.

## Notes

- A middle button stuck down would be miserable, so a watchdog releases the
  button if trackpad frames stop arriving mid-drag.
- macOS ties the two permission grants to the app's code signature. `build.sh`
  uses a real signing identity from your keychain when there is one, so the
  grants survive rebuilds; with an ad-hoc signature macOS will re-ask after
  every build.
- "Open at Login" in the menu registers the app with `SMAppService`.

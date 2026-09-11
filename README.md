# NotchWidget

A macOS notch widget for your next meeting. It sits in the menu bar wrapped
around the camera cutout, colors itself by how close the meeting is (blue when
far, amber inside ~15 min, red inside ~5 min or while live), and flashes
red↔black once a meeting is imminent until you acknowledge it. Hover to expand
a panel below the notch with your next few meetings and a carousel for other
widgets.

Meeting data comes from EventKit, so it reads every calendar in the macOS
Calendar app — iCloud, Google, Exchange, CalDAV, local — with no per-provider
setup.

## Status

Early / work in progress.

## Build & run

```sh
cd app
./tools/build-app.sh          # builds NotchWidget.app and code-signs it
open NotchWidget.app
```

Grant calendar access when prompted. The build is signed with a stable
self-signed identity so the grant survives rebuilds (see below).

Requires macOS 13+, Swift 5.9+.

## How it draws on the notch

macOS keeps the menu bar in front of everything, so a normal window can't paint
the strip beside the notch. NotchWidget uses the private CoreGraphics/SkyLight
"Spaces" API (`app/Sources/NotchWidget/CGSSpace.swift`) to place its window in a
top-level space that renders above the menu bar. This is the same technique
boring.notch uses. Because it relies on private APIs, this app cannot ship on
the Mac App Store.

## Code signing (persistent permissions)

macOS ties a privacy grant (calendar access) to the code signature. An ad-hoc
signature changes every build, so the grant would be re-prompted each time. The
build signs with a stable self-signed certificate instead:

```sh
./app/tools/codesign/create-identity.sh   # one-time: mint the signing cert
./app/tools/build-app.sh                   # signs with it
```

## Secret scanning

A pre-commit hook blocks personal information from landing in this public repo.
Install it after cloning:

```sh
./tools/install-hooks.sh
```

It scans staged changes for a gitignored denylist (`.secret-strings`), plus
generic PII (emails, phone numbers, home paths). See `tools/check-secrets.sh`.

## License

MIT, except `app/Sources/NotchWidget/CGSSpace.swift` which is MPL-2.0 (derived
from boring.notch). See [LICENSE](LICENSE).

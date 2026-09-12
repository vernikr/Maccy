# Putting this fork on your Mac

The short version:

```sh
git pull && scripts/install.sh
```

That builds Release, signs it, replaces `/Applications/Maccy.app` and keeps your clipboard history.
The rest of this file explains why it is not just "copy the .app into `/Applications`", and what the
script does to make that safe.

## The trap: a plain build loses your history

Maccy is **sandboxed** (`Maccy/Maccy.entitlements`, `com.apple.security.app-sandbox`), and it is
sandboxed by the *installed* app. Its data — the history, the settings, the `LaunchAtLogin`
registration — lives in the container:

```
~/Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/Storage.sqlite
~/Library/Containers/org.p0deje.Maccy/Data/Library/Preferences/org.p0deje.Maccy.plist
```

A `xcodebuild` build with signing turned off — which is what `bash scripts/perf.sh build` and every
performance measurement in this repository do — is **not** sandboxed, because macOS only applies the
sandbox to a signed app. Such a build reads and writes a different, empty place:

```
~/Library/Application Support/Maccy/Storage.sqlite
```

So installing an unsigned build into `/Applications` looks exactly like "my whole clipboard history
disappeared": the app starts with nothing, keeps collecting into the unsandboxed path, and the old
container sits there untouched. Nothing is lost, but the app cannot see it.

## What the script does instead

1. **Builds** Release (`.build/Build/Products/Release/Maccy.app`) after the pbxproj preflight.
2. **Signs** it with `Maccy/Maccy.entitlements` (`$(PRODUCT_BUNDLE_IDENTIFIER)` resolved), so the
   sandbox is actually applied and the app is recognised as the owner of the existing container.
   With a Developer ID / Apple Development certificate in the keychain it uses that one; with no
   certificate at all it signs **ad-hoc** (`codesign -s -`), which is enough for the sandbox to
   apply and for the container to be reused.
3. **Backs up** the app being replaced and the container, into
   `~/Library/Application Support/MaccyFork/backup-<timestamp>/` (roughly 30 MB), with a
   `WHAT-WAS-HERE.txt` naming the version that was replaced.
4. **Quits** the running Maccy, replaces `/Applications/Maccy.app`, clears the quarantine flag and
   re-registers the bundle with LaunchServices.
5. **Verifies**: signature, entitlements, installed version, and how many items the container holds.
6. **Launches** it.

`--dry-run` prints every step without touching anything, `--no-build` installs the current
`.build/Build/Products/Release/Maccy.app`, `--no-launch` skips the final `open`.

## Verified on this machine, 2026-09-12

The interesting question was whether macOS would let an ad-hoc signed build use a container that
belongs to a Developer ID signed app (upstream 2.7.1, team `MN3X4648SC`). It does — the container is
keyed by bundle identifier, and its recorded sandbox profile validation
(`.com.apple.containermanagerd.metadata.plist` → `SandboxProfileDataValidationInfo.Entitlements`)
matches the entitlements the script signs with. Measured before and after the install:

| | before | after |
| --- | --- | --- |
| installed app | `/Applications/Maccy.app` 2.7.1 (62), Developer ID | 2.7.2 (63), ad-hoc, hardened runtime |
| container inode | 110234446 | **110234446** (same directory) |
| history | 200 items | 200 items |
| unsandboxed path `~/Library/Application Support/Maccy/` | empty | empty (the sandbox really applies) |
| app writes to the container | — | yes (a copy made while it ran landed in `ZHISTORYITEM`) |

The rollback path was exercised too: the container was restored from the backup and the history came
back to exactly the 200 items it had before, with the test item gone.

## What ad-hoc signing costs

* **No notarization, so no distributable build.** That is what `docs/releasing.md` and
  `scripts/release.sh` are for: those need a Developer ID certificate. Local use does not.
* **The signature changes at every rebuild** (`adhoc` has no stable identity, just a hash of the
  binary). macOS keys some permissions by that identity, so after a reinstall it may ask again for
  **Accessibility** — Maccy posts a synthetic ⌘V when you select an item, and that needs the grant.
  If pasting stops working, re-add Maccy in System Settings → Privacy & Security → Accessibility;
  it is the rebuild, not the code.
* **Sparkle cannot update an ad-hoc build.** This fork's feed
  (`SUFeedURL` → `appcast.xml` in this repository) is wired for signed releases: Sparkle validates a
  downloaded update against the running app's signing requirement, and an ad-hoc app's requirement
  is its own hash. So updates to a local install go through `scripts/install.sh`, not through the
  app's "Check for updates". The one thing this *does* buy you is peace of mind: the fork can never
  be silently replaced by an upstream release, because upstream's appcast is not this fork's feed and
  upstream's Sparkle key is not this fork's `SUPUBLICEDKEY`.

## Rolling back

The script prints the exact commands for the backup it made. In general:

```sh
osascript -e 'tell application id "org.p0deje.Maccy" to quit'
rm -rf /Applications/Maccy.app "$HOME/Library/Containers/org.p0deje.Maccy"
ditto "<backup>/Maccy.app" /Applications/Maccy.app
ditto "<backup>/container" "$HOME/Library/Containers/org.p0deje.Maccy"
open /Applications/Maccy.app
```

Restoring the container is unnecessary if you only want the upstream app back — the container is the
same for both, which is the whole point. It matters when a run wrote something you want to undo.

## Other machines

The script needs Xcode and this checkout; it builds for the machine's own architecture and does not
produce anything distributable. Anyone else should be told to use `scripts/release.sh` with a real
Developer ID, and to install from the resulting release instead.

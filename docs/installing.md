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
   Certificates are taken in this order: `CODESIGN_IDENTITY`, "Developer ID Application", "Apple
   Development", the local certificate from `scripts/create-signing-identity.sh`, and only then
   **ad-hoc** (`codesign -s -`) — which is enough for the sandbox and the container, but not for
   anything that has to remember the app between rebuilds. The requirement the signature produces is
   printed either way, so "will this survive a rebuild?" is answered by the script rather than by a
   guess.
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
| installed app | `/Applications/Maccy.app` 2.7.1 (62), Developer ID | 2.7.2 (63), signed locally, hardened runtime |
| container inode | 110234446 | **110234446** (same directory) |
| history | 200 items | 200 items |
| unsandboxed path `~/Library/Application Support/Maccy/` | empty | empty (the sandbox really applies) |
| app writes to the container | — | yes (a copy made while it ran landed in `ZHISTORYITEM`) |

The rollback path was exercised too: the container was restored from the backup and the history came
back to exactly the 200 items it had before, with the test item gone.

## A stable identity, or why ad-hoc is the wrong default

macOS does not remember apps by their path. Whenever it has to remember a *decision* about an app —
TCC (Accessibility, Input Monitoring, Apple Events), a keychain access control list — it stores the
app's **designated requirement** and re-checks it against the app each time. What that requirement
says depends entirely on how the app was signed:

| signed with | designated requirement | survives a rebuild? |
| --- | --- | --- |
| `codesign -s -` (ad-hoc) | `cdhash H"b74ae3bd157cde91a0f86e15e57521a740fcf663"` | **no** — it is the hash of this binary |
| a certificate | `identifier "org.p0deje.Maccy" and certificate root = H"5ae9dfa7…"` | **yes** — it names the certificate |

Measured here with two *different* binaries (the Release and the Debug build, different cdhashes),
signed both ways, and the check macOS itself performs (the requirement of the older build against the
newer one, i.e. `codesign --verify --strict -R=<requirement>`):

```
certificate-signed Debug vs certificate-signed Release requirement:  MATCH
ad-hoc B               vs ad-hoc A requirement:                       NO MATCH
```

With a certificate a rebuild is still "the same app", so everything granted earlier keeps working.
With ad-hoc every rebuild is a new app: the Accessibility prompt Maccy needs for the synthetic ⌘V of
"paste" comes back, or pasting silently does nothing.

That is what `scripts/create-signing-identity.sh` creates: a self-signed code signing certificate
("Maccy Local Signing", ten years, `codeSigning` extended key usage) imported into the login keychain
with an ACL that lets `codesign` use it without prompting on every build. It is *not* a distribution
identity: nothing else trusts it, it cannot notarize, and `security find-identity -v` will not list
it as valid unless you ask for `--trust`. Signing and verification work without that trust setting
(checked: `codesign --verify --strict` passes), so the script leaves it off.

Keep the certificate. Delete it, or recreate it under a new name, and the requirement changes —
rebuilds start looking like a new app again.

One honest limit to the evidence above: it demonstrates the mechanism on this machine — the user TCC
database really does store requirements (a decoded `csreq` reads, for example,
`identifier "com.apple.weather" and anchor apple`) — but it contains **no Accessibility grant for
Maccy at all**, so there was nothing existing to preserve. The end-to-end "grant once, rebuild, still
granted" run needs a grant to exist first: grant Accessibility (System Settings → Privacy &
Security → Accessibility), then re-run `scripts/install.sh` and check that the app is not asked
again.

## What ad-hoc signing costs

* **No notarization, so no distributable build.** That is what `docs/releasing.md` and
  `scripts/release.sh` are for: those need a Developer ID certificate. Local use does not.
* **The signature changes at every rebuild**, so permissions macOS remembers about the app have to be
granted again — see the section above for the one-off fix.
* **Sparkle still updates such a build, but through the feed's key, not the signature.** The vendored
  Sparkle source settles this (`Sparkle/SUUpdateValidator.m`): an update is accepted when *either*
  the archive's EdDSA signature verifies against the running app's `SUPublicEDKey` *or* the two code
  signatures match —

  ```objc
  // Either DSA must be valid, or Apple Code Signing must be valid.
  // We allow failure of one of them, because this allows key rotation without breaking chain of trust.
  if (passedDSACheck || passedCodeSigning) { return YES; }
  ```

  The one check that consults both rejects an update whose own signature is *invalid*, not one signed
  with a different identity, and the installer's team-identifier comparison only decides whether it
  may do an atomic rename (it falls back to a plain install otherwise). So a locally signed build can
  be updated by Sparkle — as soon as a release archive signed with this fork's Sparkle key exists.
  None does yet (`appcast.xml` is an empty feed), so in practice local updates go through
  `scripts/install.sh`.

  What either way is guaranteed: the fork cannot be silently replaced by an upstream release, because
  upstream's appcast is not this fork's feed and upstream's Sparkle key is not this fork's
  `SUPUBLICEDKEY`.

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

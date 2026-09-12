#!/usr/bin/env python3
"""Adds one release to appcast.xml.

Sparkle reads this file to decide whether a newer version exists and to verify the archive it
downloads. The EdDSA signature is what makes an update acceptable: Sparkle accepts it when either
that signature verifies against the running app's SUPublicEDKey *or* the two apps' code signatures
match (SUUpdateValidator.m: `if (passedDSACheck || passedCodeSigning)`), so a locally signed build is
updateable as long as the archive is signed with this fork's key.

Usage:
  update-appcast.py --version 2.7.3 --build 64 --url <zip url> --length <bytes> \
      --signature <base64 ed signature> [--minimum-system-version 14.0] [--path appcast.xml]

The entry is inserted right after <language>en</language>, which keeps the most recent release at the
top — the order Sparkle's own tools produce.
"""

import argparse
import pathlib
import sys

TEMPLATE = """    <item>
      <title>{version}</title>
      <link>https://github.com/vernikr/Maccy/releases/tag/v{version}</link>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{minimum_system_version}</sparkle:minimumSystemVersion>
      <enclosure url="{url}"
                 sparkle:edSignature="{signature}"
                 length="{length}"
                 type="application/octet-stream" />
    </item>
"""

MARKER = "    <language>en</language>\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--length", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--minimum-system-version", default="14.0")
    parser.add_argument("--path", default="appcast.xml")
    args = parser.parse_args()

    path = pathlib.Path(args.path)
    if not path.exists():
        print(f"error: {path} does not exist", file=sys.stderr)
        return 1

    text = path.read_text(encoding="utf-8")
    if f"<sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>" in text:
        print(f"error: {path} already has an entry for {args.version}", file=sys.stderr)
        return 1
    if MARKER not in text:
        print(f"error: {path} has no <language> element to insert after", file=sys.stderr)
        return 1

    item = TEMPLATE.format(
        version=args.version,
        build=args.build,
        url=args.url,
        length=args.length,
        signature=args.signature,
        minimum_system_version=args.minimum_system_version,
    )
    path.write_text(text.replace(MARKER, MARKER + item, 1), encoding="utf-8")
    print(f"  added {args.version} (build {args.build}) to {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

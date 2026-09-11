#!/usr/bin/env python3
"""Validate an Xcode project before building it.

Xcode silently ignores a build-phase entry whose UUID is not defined in the
PBXBuildFile section: the file is simply not compiled, which only surfaces much
later as a test class that "does not exist" and "Executed 0 tests". The same
kind of silent failure happens for an object referenced nowhere, a file
reference pointing at a file that was renamed, or a source file on disk that was
never registered in a target.

This script turns all of those into loud errors:

  * every UUID referenced by the project resolves to an object;
  * every build-phase entry is a PBXBuildFile with a resolvable fileRef;
  * no build phase lists the same entry twice;
  * every file reference resolves to a file on disk;
  * every .swift file under a target's source root is compiled by that target.

Usage:
    scripts/validate-pbxproj.py [Maccy.xcodeproj] [--no-disk-check] [--quiet]

Exit code is 1 when any error is found, 0 otherwise (warnings do not fail).
"""

import json
import subprocess
import sys
from argparse import ArgumentParser
from pathlib import Path

# Keys whose value is a single object UUID.
SINGLE_REFERENCE_KEYS = (
    "buildConfigurationList",
    "containerPortal",
    "fileRef",
    "mainGroup",
    "package",
    "productRef",
    "productRefGroup",
    "productReference",
    "remoteGlobalIDString",
    "target",
    "targetProxy",
)

# Keys whose value is a list of object UUIDs.
LIST_REFERENCE_KEYS = (
    "buildPhases",
    "buildRules",
    "children",
    "dependencies",
    "files",
    "fileSystemSynchronizedGroups",
    "packageProductDependencies",
    "packageReferences",
    "targets",
)

# Locations that cannot be resolved on disk by this script.
UNRESOLVABLE_SOURCE_TREES = (
    "BUILT_PRODUCTS_DIR",
    "SDKROOT",
    "DEVELOPER_DIR",
    "PLATFORM_DIR",
    "PROJECT_DERIVED_FILE_DIR",
)

GROUP_TYPES = ("PBXGroup", "PBXVariantGroup", "XCVersionGroup")
TARGET_TYPES = ("PBXNativeTarget", "PBXAggregateTarget", "PBXLegacyTarget")
REGISTRATION_HELP = (
    "add all four entries: PBXFileReference, PBXBuildFile, the group it belongs to "
    "and the target's Sources build phase"
)


class Report:
    def __init__(self):
        self.errors = []
        self.warnings = []

    def error(self, message):
        self.errors.append(message)

    def warn(self, message):
        self.warnings.append(message)

    def print(self, quiet=False):
        for message in self.errors:
            print("error: {}".format(message))
        if not quiet:
            for message in self.warnings:
                print("warning: {}".format(message))
        summary = "{} error(s), {} warning(s)".format(len(self.errors), len(self.warnings))
        print(summary)
        return 1 if self.errors else 0


def load_project(project_path):
    pbxproj = project_path / "project.pbxproj"
    if not pbxproj.exists():
        print("error: {} not found".format(pbxproj), file=sys.stderr)
        sys.exit(2)

    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(pbxproj)],
        capture_output=True,
    )
    if result.returncode != 0:
        print(
            "error: cannot parse {}: {}".format(pbxproj, result.stderr.decode().strip()),
            file=sys.stderr,
        )
        sys.exit(2)

    return json.loads(result.stdout.decode())


def is_object(value):
    return isinstance(value, dict) and "isa" in value


def check_references(project, objects, owners, report):
    root_object = project.get("rootObject")
    if root_object not in objects:
        report.error("rootObject {} is not defined".format(root_object))

    for uuid, obj in sorted(objects.items()):
        if not is_object(obj):
            continue

        for key in SINGLE_REFERENCE_KEYS:
            value = obj.get(key)
            if isinstance(value, str) and value not in objects:
                report.error(
                    "{} ({}) has {} = {}, which is not defined".format(
                        uuid, obj["isa"], key, value
                    )
                )

        for key in LIST_REFERENCE_KEYS:
            value = obj.get(key)
            if not isinstance(value, list):
                continue
            seen = set()
            for entry in value:
                if not isinstance(entry, str):
                    continue
                if entry in seen:
                    report.error(
                        "{} ({}) lists {} twice in {}".format(uuid, obj["isa"], entry, key)
                    )
                seen.add(entry)
                if entry not in objects:
                    if key == "files" and obj["isa"].endswith("BuildPhase"):
                        report.error(
                            "build phase {} of target {} references undefined object {}: "
                            "Xcode silently skips that file ({})".format(
                                uuid, owners.get(uuid, "?"), entry, REGISTRATION_HELP
                            )
                        )
                    else:
                        report.error(
                            "{} ({}) references undefined object {} in {}".format(
                                uuid, obj["isa"], entry, key
                            )
                        )


def phase_owners(objects):
    """Maps every build phase UUID to the name of the target owning it."""
    owners = {}
    for uuid, obj in objects.items():
        if obj.get("isa") not in TARGET_TYPES:
            continue
        name = obj.get("name") or obj.get("productName") or uuid
        for phase in obj.get("buildPhases", []):
            owners[phase] = name
    return owners


def check_build_phases(objects, owners, report):
    used = {}
    for uuid, obj in sorted(objects.items()):
        if not obj.get("isa", "").endswith("BuildPhase"):
            continue
        for entry in obj.get("files", []):
            used.setdefault(entry, []).append(uuid)
            if entry in objects and objects[entry].get("isa") != "PBXBuildFile":
                report.error(
                    "build phase {} ({}) lists {}, which is a {}, not a PBXBuildFile".format(
                        uuid, owners.get(uuid, "?"), entry, objects[entry].get("isa")
                    )
                )

    for entry, phases in sorted(used.items()):
        if len(phases) > 1:
            report.error(
                "build file {} is listed by {} build phases: {}".format(
                    entry, len(phases), ", ".join(sorted(phases))
                )
            )

    for uuid, obj in sorted(objects.items()):
        if obj.get("isa") != "PBXBuildFile":
            continue
        if uuid not in used:
            report.warn(
                "PBXBuildFile {} is not listed by any build phase (dead entry)".format(uuid)
            )
        file_ref = obj.get("fileRef")
        if file_ref is None:
            # A build file for a linked product (framework, SPM package) has productRef instead.
            if obj.get("productRef") is None:
                report.error(
                    "PBXBuildFile {} has neither fileRef nor productRef ({})".format(
                        uuid, REGISTRATION_HELP
                    )
                )
        elif file_ref not in objects:
            report.error(
                "PBXBuildFile {} points at undefined fileRef {}".format(uuid, file_ref)
            )
        elif objects[file_ref].get("isa") not in GROUP_TYPES[:-1] + ("PBXFileReference",):
            report.warn(
                "PBXBuildFile {} resolves to a {} instead of a file reference ({})".format(
                    uuid, objects[file_ref].get("isa"), REGISTRATION_HELP
                )
            )


def resolve_paths(objects, main_group):
    """Maps every group/child UUID to its path relative to the project directory."""
    paths = {main_group: Path(".")}
    stack = [main_group]
    while stack:
        uuid = stack.pop()
        obj = objects.get(uuid)
        if obj is None:
            continue
        base = paths[uuid]
        for child in obj.get("children", []):
            child_obj = objects.get(child)
            if child_obj is None:
                continue
            source_tree = child_obj.get("sourceTree", "<group>")
            if source_tree != "<group>":
                continue

            if child_obj.get("isa") in GROUP_TYPES:
                # A group contributes to the path only when it has one; a group with
                # just a name (e.g. Products) does not move its children on disk.
                segment = child_obj.get("path")
                if segment:
                    paths[child] = base / segment
                else:
                    paths[child] = base
                stack.append(child)
            else:
                segment = child_obj.get("path") or child_obj.get("name")
                if segment:
                    paths[child] = base / segment

    return paths


def check_disk(objects, paths, project_dir, report):
    for uuid, obj in sorted(objects.items()):
        if obj.get("isa") != "PBXFileReference":
            continue
        if obj.get("sourceTree", "<group>") in UNRESOLVABLE_SOURCE_TREES:
            continue
        relative = paths.get(uuid)
        if relative is None:
            report.warn("cannot resolve the location of file reference {} ({})".format(
                uuid, obj.get("path") or obj.get("name") or "?"
            ))
            continue
        resolved = project_dir / relative
        if not resolved.exists():
            report.error(
                "file reference points at a missing file: {} ({}), referenced by {}".format(
                    relative, uuid, obj.get("lastKnownFileType", "unknown type")
                )
            )


def registered_sources(objects, paths, target, phases):
    """Returns the set of relative paths compiled by `target`'s Sources phases."""
    registered = set()
    for phase_uuid in target.get("buildPhases", []):
        phase = objects.get(phase_uuid)
        if phase is None or phase.get("isa") != "PBXSourcesBuildPhase":
            continue
        phases.add(phase_uuid)
        for entry in phase.get("files", []):
            build_file = objects.get(entry)
            if build_file is None:
                continue
            file_ref = build_file.get("fileRef")
            relative = paths.get(file_ref)
            if relative is not None:
                registered.add(str(relative))
    return registered


def check_unregistered_sources(objects, paths, project_dir, report):
    known = {
        str(paths[uuid])
        for uuid, obj in objects.items()
        if obj.get("isa") == "PBXFileReference" and uuid in paths
    }

    for uuid, target in sorted(objects.items()):
        if target.get("isa") not in TARGET_TYPES:
            continue
        name = target.get("name") or target.get("productName") or uuid

        phases = set()
        registered = registered_sources(objects, paths, target, phases)
        if not phases:
            continue

        root = None
        for group_uuid, group in objects.items():
            if group.get("isa") == "PBXGroup" and group.get("path") == name:
                root = paths.get(group_uuid)
                break
        if root is None:
            report.warn(
                "cannot locate the source root of target {} (no group with path '{}'); "
                "skipping the unregistered-source check".format(name, name)
            )
            continue

        root_dir = project_dir / root
        if not root_dir.is_dir():
            continue

        for path in sorted(root_dir.rglob("*.swift")):
            relative = str(path.relative_to(project_dir))
            if relative in registered:
                continue
            if relative in known:
                # Registered in the project but kept out of this target on purpose?
                report.warn(
                    "{} is in the project but not compiled by target {}".format(relative, name)
                )
            else:
                # This is the trap: a new file that was never registered anywhere.
                report.warn(
                    "{} exists on disk but target {} never compiles it ({}); delete it if it is "
                    "dead code".format(relative, name, REGISTRATION_HELP)
                )


def main():
    parser = ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "project",
        nargs="?",
        default=str(Path(__file__).resolve().parent.parent / "Maccy.xcodeproj"),
        help="path to the .xcodeproj bundle (default: Maccy.xcodeproj of this repository)",
    )
    parser.add_argument(
        "--no-disk-check",
        action="store_true",
        help="skip checks that resolve file references on disk",
    )
    parser.add_argument("--quiet", action="store_true", help="hide warnings")
    args = parser.parse_args()

    project_path = Path(args.project).resolve()
    project_dir = project_path.parent
    project = load_project(project_path)
    objects = project.get("objects", {})
    report = Report()

    owners = phase_owners(objects)
    check_references(project, objects, owners, report)
    check_build_phases(objects, owners, report)

    if not args.no_disk_check:
        main_group = objects.get(project.get("rootObject"), {}).get("mainGroup")
        paths = resolve_paths(objects, main_group)
        check_disk(objects, paths, project_dir, report)
        check_unregistered_sources(objects, paths, project_dir, report)

    sys.exit(report.print(args.quiet))


if __name__ == "__main__":
    main()

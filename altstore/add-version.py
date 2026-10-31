#!/usr/bin/env python3
"""Adds a release's iOS build to the AltStore source (altstore/source.json).

    altstore/add-version.py VERSION BUILD IPA_FILE RELEASE_NOTES.md [DATE]

VERSION is the iOS version (0.28.0), BUILD its CFBundleVersion (48), IPA_FILE the
docho-VERSION.ipa attached to the GitHub release, and RELEASE_NOTES.md the release body:
only its "## iOS..." section goes into AltStore. DATE defaults to now (ISO 8601).
Run it for every release that carries an IPA, then commit source.json to main.
"""
import datetime
import json
import os
import re
import sys

SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "source.json")
BUNDLE_ID = "io.github.grillza.docho"
REPO = "Grillza/docho"
TAG_PREFIX = "v"


def ios_section(notes: str) -> str:
    lines = notes.splitlines()
    start = next((i for i, line in enumerate(lines) if line.startswith("## iOS")), None)
    if start is None:
        return notes.strip()
    rest = lines[start + 1:]
    end = next((i for i, line in enumerate(rest) if line.startswith("## ")), len(rest))
    text = "\n".join(rest[:end])
    # AltStore shows plain text: drop Markdown emphasis, code and link syntax.
    text = re.sub(r"^#+\s*", "", text, flags=re.MULTILINE)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = text.replace("**", "").replace("`", "")
    text = re.sub(r"^- ", "• ", text, flags=re.MULTILINE)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def main() -> None:
    if len(sys.argv) not in (5, 6):
        sys.exit(__doc__)
    version, build, ipa, notes_path = sys.argv[1:5]
    date = sys.argv[5] if len(sys.argv) == 6 else datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    name = os.path.basename(ipa)
    if name != f"docho-{version}.ipa":
        sys.exit(f"Expected docho-{version}.ipa, got {name}")
    # The release tag follows Android's version, which can differ from iOS's by a patch.
    tag = os.environ.get("DOCHO_TAG", f"{TAG_PREFIX}{version}")

    with open(notes_path, encoding="utf-8") as f:
        notes = ios_section(f.read())
    with open(SOURCE, encoding="utf-8") as f:
        source = json.load(f)

    app = next(a for a in source["apps"] if a["bundleIdentifier"] == BUNDLE_ID)
    app["versions"] = [v for v in app["versions"] if v["version"] != version]
    app["versions"].insert(0, {
        "version": version,
        "buildVersion": str(build),
        "date": date,
        "localizedDescription": notes,
        "downloadURL": f"https://github.com/{REPO}/releases/download/{tag}/{name}",
        "size": os.path.getsize(ipa),
        "minOSVersion": "18.0",
    })

    with open(SOURCE, "w", encoding="utf-8") as f:
        json.dump(source, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"Added {version} ({build}) from {tag}")


if __name__ == "__main__":
    main()

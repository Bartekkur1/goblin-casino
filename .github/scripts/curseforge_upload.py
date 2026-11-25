"""Upload an addon zip to CurseForge (WoW upload API).

The game version comes from the CF_GAME_VERSION environment variable (names, slugs or ids,
comma separated) or, when that is empty, from the TOC's Interface number (16001 -> "1.60.1").
When no version matches, the script lists what CurseForge offers and fails, so the right value
can be put into the CF_GAME_VERSION repository variable.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request
import uuid

API = "https://wow.curseforge.com/api"
HEADERS = {"User-Agent": "goblin-casino-release"}


def request(url, token, data=None, content_type=None):
    headers = dict(HEADERS, **{"X-Api-Token": token})
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if data else "GET")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode("utf-8") or "null")
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "replace")
        sys.exit(f"::error::CurseForge {err.code} for {url}: {body}")


def interface_to_name(interface):
    i = int(interface)
    return f"{i // 10000}.{(i // 100) % 100}.{i % 100}"


def pick_versions(token, interface):
    types = {t["id"]: t for t in request(f"{API}/game/version-types", token)}
    versions = request(f"{API}/game/versions", token)

    def label(v):
        t = types.get(v.get("gameVersionTypeID"), {})
        return f'{v["name"]} (id {v["id"]}, {t.get("name", "?")})'

    wanted = [w.strip() for w in os.environ.get("CF_GAME_VERSION", "").split(",") if w.strip()]
    if not wanted and interface:
        wanted = [interface_to_name(interface)]
    chosen = []
    for w in wanted:
        lw = w.lower()
        hits = [v for v in versions
                if str(v["id"]) == w or v["name"].lower() == lw or str(v.get("slug", "")).lower() == lw]
        chosen.extend(hits)
    if chosen:
        print("Game versions:", ", ".join(label(v) for v in chosen))
        return [v["id"] for v in chosen]

    print(f"::error::No CurseForge game version matches {wanted}.")
    print("Version types:", ", ".join(f'{t["name"]} [{t.get("slug")}] (id {t["id"]})' for t in types.values()))
    major = wanted[0].split(".")[0] + "." if wanted else ""
    near = [v for v in versions if major and v["name"].startswith(major)]
    near.sort(key=lambda v: v["id"], reverse=True)
    print("Versions starting with", repr(major), ":")
    for v in near[:60]:
        print("  ", label(v))
    print("Set the variable CF_GAME_VERSION in the environment curseforge (Settings > Environments >"
          " curseforge > Environment variables) to the right name or id, then re-run this workflow.")
    sys.exit(1)


def multipart(fields, file_field, path):
    boundary = uuid.uuid4().hex
    out = []
    for name, value in fields.items():
        out.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    with open(path, "rb") as fh:
        data = fh.read()
    out.append((f'--{boundary}\r\nContent-Disposition: form-data; name="{file_field}"; '
                f'filename="{os.path.basename(path)}"\r\nContent-Type: application/zip\r\n\r\n').encode())
    out.append(data)
    out.append(f"\r\n--{boundary}--\r\n".encode())
    return b"".join(out), f"multipart/form-data; boundary={boundary}"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--project", required=True)
    p.add_argument("--interface", default="")
    p.add_argument("--version", required=True)
    p.add_argument("--zip", required=True)
    p.add_argument("--changelog", required=True)
    p.add_argument("--release-type", default="release", choices=["release", "beta", "alpha"])
    args = p.parse_args()

    token = os.environ.get("CF_API_KEY", "")
    if not token:
        sys.exit("::error::CF_API_KEY is not set.")
    with open(args.changelog, encoding="utf-8") as fh:
        changelog = fh.read()

    metadata = {
        "changelog": changelog,
        "changelogType": "markdown",
        "displayName": f"Goblin Casino {args.version}",
        "gameVersions": pick_versions(token, args.interface),
        "releaseType": args.release_type,
    }
    body, ctype = multipart({"metadata": json.dumps(metadata)}, "file", args.zip)
    result = request(f"{API}/projects/{args.project}/upload-file", token, body, ctype)
    print("Uploaded to CurseForge:", result)


if __name__ == "__main__":
    main()

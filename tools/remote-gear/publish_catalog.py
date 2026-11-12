#!/usr/bin/env python3
"""Publish a Recommended Gear catalog to the STAGING object, safely. Dry run unless --upload.

    python3 tools/remote-gear/publish_catalog.py docs/remote-gear/staging/publication-a.json
    SUPABASE_SERVICE_ROLE_KEY=... python3 tools/remote-gear/publish_catalog.py --upload docs/remote-gear/staging/publication-a.json

Steps, in order:
  1. Read the template and the LIVE staging object (public GET, no key).
  2. Stamp a fresh `revision` and a `publishedAt` strictly newer than the live one:
     max(now in whole seconds, live + 1), so rapid successive publishes still increase.
  3. Validate the stamped document AND its succession over the live one with validate_catalog.py
     (the same rules the apps apply). Anything a device would reject stops here.
  4. --upload only: upload with Content-Type application/json and Cache-Control max-age=60, then
     read the public URL back and require identical bytes.

Production is deliberately not supported by this tool. The service-role key is read only from
the environment on the publishing machine; it must never be put in an app, a file in the
repository or a browser.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request
import uuid

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import validate_catalog as v  # noqa: E402

PROJECT_URL = "https://zefkbtscieokkdenvnkg.supabase.co"
BUCKET = "recommended-gear"
STAGING_PATH = "staging/catalog-v1.json"
CACHE_CONTROL = "max-age=60"


class PublishError(Exception):
    pass


def public_url(project_url: str = PROJECT_URL, path: str = STAGING_PATH) -> str:
    return f"{project_url}/storage/v1/object/public/{BUCKET}/{path}"


def upload_url(project_url: str = PROJECT_URL, path: str = STAGING_PATH) -> str:
    return f"{project_url}/storage/v1/object/{BUCKET}/{path}"


def classify_live_response(status: int, body: bytes) -> str:
    """'published' (a document exists), 'absent' (no object yet: first publication), or raises.

    Supabase Storage answers a missing bucket and a missing object with HTTP 400 and a JSON error,
    so the error text, not the status code, tells them apart.
    """
    if status == 200:
        return "published"
    try:
        error = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        error = {}
    text = " ".join(str(error.get(k, "")) for k in ("error", "message", "code")).lower()
    if "bucket" in text and "not found" in text or "nosuchbucket" in text:
        raise PublishError(f"the '{BUCKET}' bucket does not exist (see docs/remote-gear/STAGING_SETUP.md)")
    if status in (400, 404) and ("not found" in text or "not_found" in text or "nosuchkey" in text):
        return "absent"
    raise PublishError(f"unexpected live response: HTTP {status} {body[:200]!r}")


def stamp(template: dict, live: dict | None, now: float, slug: str) -> dict:
    """A copy of `template` with a never-used revision and a strictly newer whole-second publishedAt."""
    document = json.loads(json.dumps(template))
    floor = int(now)
    if live is not None:
        floor = max(floor, int(live["publishedAt"]) + 1)
    document["publishedAt"] = floor
    document["revision"] = f"staging-{floor}-{slug}-{uuid.uuid4().hex[:8]}"
    return document


def encode(document: dict) -> bytes:
    return (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def fetch(url: str) -> tuple[int, bytes, dict]:
    request = urllib.request.Request(url, headers={"Cache-Control": "no-cache"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, response.read(), dict(response.headers)
    except urllib.error.HTTPError as error:
        return error.code, error.read(), dict(error.headers)


def prepare(template_path: str, live_status: int, live_body: bytes, now: float) -> tuple[dict, bytes, dict | None]:
    template = json.loads(pathlib.Path(template_path).read_text())
    state = classify_live_response(live_status, live_body)
    live = None
    if state == "published":
        live, _ = v.validate_bytes(live_body)
    slug = pathlib.Path(template_path).stem
    document = stamp(template, live, now, slug)
    raw = encode(document)
    v.validate_bytes(raw)
    if live is not None:
        v.check_successor(live, live_body, document, raw, {live["revision"]})
    return document, raw, live


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("template")
    parser.add_argument("--upload", action="store_true", help="actually upload (default: dry run)")
    parser.add_argument("--out", help="also write the stamped document here")
    args = parser.parse_args(argv)

    status, body, _ = fetch(public_url())
    try:
        document, raw, live = prepare(args.template, status, body, time.time())
    except (PublishError, v.Invalid, v.Unsupported) as error:
        print(f"STOPPED: {error}")
        return 1
    print(f"live: {'revision ' + live['revision'] + ', publishedAt ' + str(live['publishedAt']) if live else 'no staging publication yet'}")
    print(f"next: revision {document['revision']}, publishedAt {document['publishedAt']}, "
          f"{sum(1 for b in document['brands'] if not b.get('hidden'))} visible brand(s), {len(raw)} bytes")
    if args.out:
        pathlib.Path(args.out).write_bytes(raw)
    if not args.upload:
        print(f"dry run: would upload to {upload_url()} with Cache-Control {CACHE_CONTROL}")
        return 0

    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip()
    if not key:
        print("STOPPED: set SUPABASE_SERVICE_ROLE_KEY in this shell (never in the app or the repository)")
        return 1
    request = urllib.request.Request(upload_url(), data=raw, method="POST", headers={
        "Authorization": f"Bearer {key}", "apikey": key, "Content-Type": "application/json",
        "Cache-Control": CACHE_CONTROL, "x-upsert": "true",
    })
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            print(f"uploaded: HTTP {response.status}")
    except urllib.error.HTTPError as error:
        print(f"STOPPED: upload failed: HTTP {error.code} {error.read()[:300]!r}")
        return 1

    status, served, headers = fetch(public_url())
    if status != 200 or served != raw:
        print(f"WARNING: public URL returned HTTP {status} with {'different' if served != raw else 'the same'} bytes "
              f"(CDN may still serve the previous version for up to {CACHE_CONTROL})")
        return 2
    print(f"verified: public URL serves the new bytes; Cache-Control={headers.get('Cache-Control')} ETag={headers.get('ETag')}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

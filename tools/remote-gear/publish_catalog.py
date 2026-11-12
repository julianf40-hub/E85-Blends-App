#!/usr/bin/env python3
"""Publish a Recommended Gear catalog to the STAGING object, safely. Dry run unless --upload.

    python3 tools/remote-gear/publish_catalog.py docs/remote-gear/staging/publication-a.json
    SUPABASE_SERVICE_ROLE_KEY=... python3 tools/remote-gear/publish_catalog.py --upload docs/remote-gear/staging/publication-a.json

Steps, in order:
  1. Read the template and the LIVE staging object. A dry run reads the public (CDN) URL with no
     key. --upload reads the authenticated ORIGIN endpoint instead, so a stale CDN copy cannot make
     the tool stamp a publication that is not newer than the real live one.
  2. Stamp a fresh `revision` and a `publishedAt` strictly newer than the live one:
     max(now in whole seconds, live + 1), so rapid successive publishes still increase. Refuse if
     the live publishedAt is more than 5 minutes in the future (a publisher with a wrong clock).
  3. Validate the stamped document AND its succession over the live one with validate_catalog.py
     (the same rules the apps apply). Anything a device would reject stops here.
  4. --upload only: upload with Content-Type application/json and Cache-Control max-age=60. Then
     verify separately:
       - ORIGIN read-back (authoritative): must hold exactly our bytes. If not, another
         publication replaced ours: reported as CONFLICT, exit 4.
       - PUBLIC read-back (what devices see, through the CDN): may lag by up to max-age. A lag is
         reported as "PUBLISHED, CDN not yet updated", exit 3, never as "nothing published".

Concurrency: NOT protected. Supabase Storage has no conditional (compare-and-swap) write, so
this tool cannot prevent two people overwriting each other. The origin read-back (step 4) catches
only some conflicts: another upload that lands before the read-back. It misses an overwrite that
lands afterwards, and two publishers who read the same live document and stamp the same second
(the later write wins silently, and devices that already accepted the first reject it). Staging
REQUIRES one publisher at a time; the future dashboard serializes publications with a database
lock (docs/remote-gear/PUBLISHING_DASHBOARD.md).

Credentials: the service-role key bypasses every Storage and database access rule and works from
any machine that has it. It is not tied to a device. It is read only from the environment
variable SUPABASE_SERVICE_ROLE_KEY, sent only in request headers, and redacted from any server
text this tool prints. Never put it in an app, a file in the repository, a browser or a chat.
Rotate it in the Supabase dashboard if it is ever exposed.

Production is deliberately not supported by this tool.
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


def origin_url(project_url: str = PROJECT_URL, path: str = STAGING_PATH) -> str:
    """Authenticated download: served by Storage itself, not the public CDN cache."""
    return f"{project_url}/storage/v1/object/authenticated/{BUCKET}/{path}"


MAX_FUTURE_SKEW = 300


def redact(text: str, secret: str | None) -> str:
    return text.replace(secret, "<redacted>") if secret else text


def verification_outcome(ours: bytes, origin_status: int, origin_bytes: bytes,
                         public_status: int, public_bytes: bytes) -> tuple[str, int]:
    """Classifies the post-upload checks. Returns (message, exit code).

    The upload already succeeded when this is called; nothing here may say otherwise.
    """
    if origin_status != 200:
        failure = "could not connect" if origin_status == 0 else f"HTTP {origin_status}"
        return (f"UPLOADED, but the origin read-back failed ({failure}); "
                "check the object in the Supabase dashboard before publishing again", 5)
    if origin_bytes != ours:
        return ("CONFLICT: uploaded, but the origin now holds a different document: another "
                "publication replaced ours. Do not publish again until you know which is live", 4)
    if public_status == 200 and public_bytes == ours:
        return ("PUBLISHED and verified: origin and public URL serve the new document", 0)
    public = "could not connect" if public_status == 0 else f"HTTP {public_status}"
    return (f"PUBLISHED (origin verified). The public URL does not serve it yet ({public}); "
            f"the CDN may keep the previous copy for up to {CACHE_CONTROL}", 3)


def classify_live_response(status: int, body: bytes) -> str:
    """'published' (a document exists), 'absent' (no object yet: first publication), or raises.

    Supabase Storage answers a missing bucket and a missing object with HTTP 400 and a JSON error,
    so the error text, not the status code, tells them apart.
    """
    if status == 200:
        return "published"
    if status == 0:
        raise PublishError(f"could not reach Storage ({body.decode('utf-8', 'replace')}); nothing was uploaded")
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


def fetch(url: str, key: str | None = None) -> tuple[int, bytes, dict]:
    """(HTTP status, body, headers). A transport failure (no connection, reset, timeout) returns
    status 0 with the reason as the body, so callers report it instead of crashing; after a
    successful upload that keeps "uploaded but unverified" distinct from "not published"."""
    headers = {"Cache-Control": "no-cache"}
    if key:
        headers.update({"Authorization": f"Bearer {key}", "apikey": key})
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, response.read(), dict(response.headers)
    except urllib.error.HTTPError as error:
        return error.code, error.read(), dict(error.headers)
    except (urllib.error.URLError, OSError) as error:  # includes timeouts
        reason = getattr(error, "reason", error)
        return 0, str(reason).encode("utf-8", "replace"), {}


def prepare(template_path: str, live_status: int, live_body: bytes, now: float) -> tuple[dict, bytes, dict | None]:
    template = json.loads(pathlib.Path(template_path).read_text())
    state = classify_live_response(live_status, live_body)
    live = None
    if state == "published":
        live, _ = v.validate_bytes(live_body)
        if live["publishedAt"] > now + MAX_FUTURE_SKEW:
            raise PublishError(f"the live publishedAt ({live['publishedAt']}) is more than "
                               f"{MAX_FUTURE_SKEW} s in the future; a publisher's clock is wrong. Resolve that first")
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

    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip() or None
    if args.upload and not key:
        print("STOPPED: set SUPABASE_SERVICE_ROLE_KEY in this shell (never in the app, the repository or a chat)")
        return 1
    # Uploads base the stamp on the origin copy; a dry run (no key needed) uses the public URL.
    status, body, _ = fetch(origin_url(), key) if args.upload else fetch(public_url())
    try:
        document, raw, live = prepare(args.template, status, body, time.time())
    except (PublishError, v.Invalid, v.Unsupported) as error:
        print(f"STOPPED: {redact(str(error), key)}")
        return 1
    print(f"live ({'origin' if args.upload else 'public URL'}): "
          f"{'revision ' + live['revision'] + ', publishedAt ' + str(live['publishedAt']) if live else 'no staging publication yet'}")
    print(f"next: revision {document['revision']}, publishedAt {document['publishedAt']}, "
          f"{sum(1 for b in document['brands'] if not b.get('hidden'))} visible brand(s), {len(raw)} bytes")
    if args.out:
        pathlib.Path(args.out).write_bytes(raw)
    if not args.upload:
        print(f"dry run: would upload to {upload_url()} with Cache-Control {CACHE_CONTROL}")
        return 0

    request = urllib.request.Request(upload_url(), data=raw, method="POST", headers={
        "Authorization": f"Bearer {key}", "apikey": key, "Content-Type": "application/json",
        "Cache-Control": CACHE_CONTROL, "x-upsert": "true",
    })
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            print(f"upload: HTTP {response.status}")
    except urllib.error.HTTPError as error:
        detail = redact(error.read()[:300].decode("utf-8", "replace"), key)
        print(f"NOT PUBLISHED: upload refused: HTTP {error.code} {detail}")
        return 1
    except urllib.error.URLError as error:
        print(f"UNKNOWN: the upload request did not complete ({redact(str(error.reason), key)}); "
              "it may or may not have been stored. Check the origin before retrying")
        return 6

    origin_status, origin_bytes, _ = fetch(origin_url(), key)
    public_status, public_bytes, headers = fetch(public_url())
    message, code = verification_outcome(raw, origin_status, origin_bytes, public_status, public_bytes)
    print(message)
    if code == 0:
        print(f"public headers: Cache-Control={headers.get('Cache-Control')} ETag={headers.get('ETag')}")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

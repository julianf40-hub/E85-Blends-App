#!/usr/bin/env python3
"""Publish a Recommended Gear catalog to the STAGING object, safely. Dry run unless --upload.

    python3 tools/remote-gear/publish_catalog.py docs/remote-gear/staging/publication-a.json
    SUPABASE_SECRET_KEY=... python3 tools/remote-gear/publish_catalog.py --verify-key docs/remote-gear/staging/publication-a.json
    SUPABASE_SECRET_KEY=... python3 tools/remote-gear/publish_catalog.py --upload docs/remote-gear/staging/publication-a.json

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
       - ORIGIN read-back (authoritative): must hold exactly our bytes. Storage can briefly
         serve the previous object after an overwrite, so a failed or still-previous read-back
         is retried (reads only). All verification reads share one 30 s wall-clock deadline that
         cuts off slow connects, headers and bodies, and closes the connection. Still the previous
         document after that: exit 7 (unconfirmed, read back before publishing again). Still
         failing or missing: exit 5. Any other document: CONFLICT, exit 4 (content we did not
         write is live; the tool cannot tell who wrote it).
       - PUBLIC read-back (what devices see, through the CDN): may lag by up to max-age. A lag is
         reported as "PUBLISHED, CDN not yet updated", exit 3, never as "nothing published".

Concurrency: NOT protected. Supabase Storage has no conditional (compare-and-swap) write, so
this tool cannot prevent two people overwriting each other. The origin read-back (step 4) catches
only some conflicts: another upload that lands before the read-back. It misses an overwrite that
lands afterwards, and two publishers who read the same live document and stamp the same second
(the later write wins silently, and devices that already accepted the first reject it). Staging
REQUIRES one publisher at a time; the future dashboard serializes publications with a database
lock (docs/remote-gear/PUBLISHING_DASHBOARD.md).

Credentials: a secret key (`sb_secret_…`, preferred) or the legacy service-role JWT bypasses
every Storage and database access rule and works from any machine that has it. It is not tied to
a device. It is read only from the environment variable SUPABASE_SECRET_KEY (or the legacy
SUPABASE_SERVICE_ROLE_KEY), sent only in request headers (a secret key only as `apikey`, never as
a Bearer token), and redacted from any server text this tool prints. A publishable key is
refused. Never put a key in an app, a file in the repository, a browser or a chat. Use a secret
key dedicated to this publisher, so it can be deleted on its own if it is ever exposed.

Production is deliberately not supported by this tool.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import pathlib
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
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


# Verification after an upload (origin read-back with retries, then the public read) runs under ONE
# wall-clock deadline: VERIFY_BUDGET seconds in all, of which the last PUBLIC_READ_RESERVE seconds
# are kept for the public read. Every read is a GET (the upload is never repeated) and is cut off
# at its deadline whatever the server does: slow connect, trickled headers, or a trickled success
# or error body. Storage can serve the previous object for a moment right after an overwrite, so
# a read-back that fails or still shows the pre-upload document is retried within that budget.
VERIFY_BUDGET = 30.0
PUBLIC_READ_RESERVE = 10.0
READBACK_DELAYS = (0, 1, 2, 3, 4)
READBACK_REQUEST_TIMEOUT = 10.0
DEADLINE_EXCEEDED = b"verification deadline reached"


def request_headers(key: str | None) -> dict:
    headers = {"Cache-Control": "no-cache"}
    if key:
        headers.update(auth_headers(key))
    return headers


def bounded_fetch(url: str, key: str | None, deadline: float, clock=None) -> tuple[int, bytes, dict]:
    """GET `url`, returning by `deadline` (a `time.monotonic()` value) whatever the server does.

    The request runs on a worker thread with its own connection. The caller waits only until the
    deadline; if the worker is still busy (connecting, waiting for headers, or reading a success
    or error body), the socket is shut down and the connection closed, which unblocks and ends
    the worker, and (0, DEADLINE_EXCEEDED, {}) is returned. A transport failure returns status 0
    with the reason as the body, like `fetch`. Only a DNS lookup cannot be interrupted; it is
    abandoned (daemon thread) and never sends a request.
    """
    clock = clock or time.monotonic
    parts = urllib.parse.urlsplit(url)
    connection_class = http.client.HTTPSConnection if parts.scheme == "https" else http.client.HTTPConnection
    target = parts.path + (f"?{parts.query}" if parts.query else "")
    state = {"connection": None, "result": None}
    stop = threading.Event()

    def work():
        connection = None
        try:
            remaining = deadline - clock()
            if remaining <= 0 or stop.is_set():
                return
            connection = connection_class(parts.hostname, parts.port,
                                          timeout=min(READBACK_REQUEST_TIMEOUT, remaining))
            state["connection"] = connection
            connection.connect()
            if stop.is_set():
                return
            connection.request("GET", target, headers=request_headers(key))
            response = connection.getresponse()
            body = response.read()
            if not stop.is_set():
                state["result"] = (response.status, body, dict(response.getheaders()))
        except Exception as error:  # noqa: BLE001 - socket timeouts, resets, HTTP errors, and
            # whatever http.client raises once the caller has shut the socket down
            if not stop.is_set():
                state["result"] = (0, str(error).encode("utf-8", "replace"), {})
        finally:
            if connection is not None:
                try:
                    connection.close()
                except Exception:  # noqa: BLE001
                    pass

    worker = threading.Thread(target=work, name="publisher-bounded-fetch", daemon=True)
    worker.start()
    worker.join(max(0.0, deadline - clock()))
    if worker.is_alive() or state["result"] is None:
        stop.set()
        # Shutting the socket down unblocks a read in progress; the worker then closes its own
        # connection. Closing it from here is only a fallback for a worker that did not exit.
        connection = state["connection"]
        sock = connection.sock if connection is not None else None
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        worker.join(1.0)
        if worker.is_alive() and connection is not None:
            try:
                connection.close()
            except Exception:  # noqa: BLE001
                pass
        return 0, DEADLINE_EXCEEDED, {}
    return state["result"]


def read_back_origin(fetch_origin, ours: bytes, previous: bytes | None, deadline: float,
                     delays=None, sleep=None, clock=None) -> tuple[int, bytes]:
    """(status, body) of the origin once it settles, by `deadline` (a `clock()` value).

    `fetch_origin(attempt_deadline)` performs one read that must return by `attempt_deadline`
    (see `bounded_fetch`) and returns (status, body, headers). Retries while the origin fails or
    still serves `previous`; stops at once on our exact bytes or on any other 200 document. Each
    attempt gets at most READBACK_REQUEST_TIMEOUT seconds, so one hanging read leaves time for a
    retry, and no attempt or wait goes past `deadline`.
    """
    sleep, clock = sleep or time.sleep, clock or time.monotonic
    status, body = 0, b"no read-back attempted"
    for delay in READBACK_DELAYS if delays is None else delays:
        if clock() + delay >= deadline:
            break
        sleep(delay)
        now = clock()
        if now >= deadline:
            break
        status, body, _ = fetch_origin(min(deadline, now + READBACK_REQUEST_TIMEOUT))
        if status == 200 and (body == ours or body != previous):
            break
    return status, body


def origin_object_missing(status: int, body: bytes) -> bool:
    if status not in (400, 404):
        return False
    try:
        return classify_live_response(status, body) == "absent"
    except PublishError:
        return False


def verification_outcome(ours: bytes, origin_status: int, origin_bytes: bytes,
                         public_status: int, public_bytes: bytes,
                         previous: bytes | None = None) -> tuple[str, int]:
    """Classifies the post-upload checks. Returns (message, exit code).

    The upload already succeeded when this is called; nothing here may say otherwise.
    `previous` is the live document read before the upload (None for a first publication).
    """
    if origin_status != 200:
        if origin_object_missing(origin_status, origin_bytes):
            failure = "the origin reports no object at this path"
        elif origin_status == 0 and origin_bytes == DEADLINE_EXCEEDED:
            failure = "timed out: verification deadline reached"
        elif origin_status == 0:
            failure = "could not connect"
        else:
            failure = f"HTTP {origin_status}"
        return (f"UPLOADED, but the origin read-back failed after retrying ({failure}); "
                "check the object in the Supabase dashboard before publishing again", 5)
    if origin_bytes != ours and previous is not None and origin_bytes == previous:
        return ("UPLOADED, but the origin still serves the previous publication after retrying; "
                "Storage may not be consistent yet. Read the object back before publishing again", 7)
    if origin_bytes != ours:
        return ("CONFLICT: uploaded, but the origin serves content that is neither our upload nor "
                "the publication live before it. The cause is not known (possibly another "
                "publisher). Do not publish again until you know which document is live", 4)
    if public_status == 200 and public_bytes == ours:
        return ("PUBLISHED and verified: origin and public URL serve the new document", 0)
    if public_status == 0 and public_bytes == DEADLINE_EXCEEDED:
        public = "timed out: verification deadline reached"
    elif public_status == 0:
        public = "could not connect"
    else:
        public = f"HTTP {public_status}"
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


KEY_ENV_VARS = ("SUPABASE_SECRET_KEY", "SUPABASE_SERVICE_ROLE_KEY")


def read_key(environ) -> tuple[str | None, str | None]:
    """(key, name of the variable it came from). SUPABASE_SECRET_KEY wins over the legacy name."""
    for name in KEY_ENV_VARS:
        value = environ.get(name, "").strip()
        if value:
            return value, name
    return None, None


def auth_headers(key: str) -> dict:
    """Request headers for a privileged key. Raises PublishError (never quoting the key) otherwise.

    - `sb_secret_…` (new secret key): sent ONLY as `apikey`. It is not a JWT; the Supabase gateway
      turns it into a service-role request. Storage rejects a non-JWT Bearer token
      ("Invalid Compact JWS"), so it must not be sent as one.
    - `eyJ…` (legacy service_role JWT): `apikey` and `Authorization: Bearer`, as before.
    """
    if key.startswith("sb_secret_"):
        return {"apikey": key}
    if key.startswith("eyJ"):
        return {"apikey": key, "Authorization": f"Bearer {key}"}
    if key.startswith("sb_publishable_"):
        raise PublishError("the key is a publishable (public) key, which cannot write to Storage; "
                           "use a secret key (sb_secret_…)")
    raise PublishError("the key is neither a secret key (sb_secret_…) nor a legacy service-role JWT")


def fetch(url: str, key: str | None = None, timeout: float = 20) -> tuple[int, bytes, dict]:
    """(HTTP status, body, headers). A transport failure (no connection, reset, timeout) returns
    status 0 with the reason as the body, so callers report it instead of crashing; after a
    successful upload that keeps "uploaded but unverified" distinct from "not published"."""
    request = urllib.request.Request(url, headers=request_headers(key))
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
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
    parser.add_argument("--verify-key", action="store_true",
                        help="only check that the key can read the staging origin (no upload)")
    args = parser.parse_args(argv)

    key, key_source = read_key(os.environ)
    if (args.upload or args.verify_key) and not key:
        print("STOPPED: set SUPABASE_SECRET_KEY (or the legacy SUPABASE_SERVICE_ROLE_KEY) in this shell "
              "(never in the app, the repository or a chat)")
        return 1
    if args.upload or args.verify_key:
        try:
            auth_headers(key)
        except PublishError as error:
            print(f"STOPPED: {key_source}: {error}")
            return 1
    if args.verify_key:
        kind = "secret key" if key.startswith("sb_secret_") else "legacy service-role JWT"
        status, body, _ = fetch(origin_url(), key)
        if status == 200 or origin_object_missing(status, body):
            print(f"key accepted ({kind} from {key_source}): origin read HTTP {status}")
            return 0
        failure = "could not connect" if status == 0 else f"HTTP {status}"
        print(f"key NOT accepted ({kind} from {key_source}): origin read {failure}")
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
        **auth_headers(key), "Content-Type": "application/json",
        "Cache-Control": CACHE_CONTROL, "x-upsert": "true",
    })
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            print(f"upload: HTTP {response.status}")
    except urllib.error.HTTPError as error:
        detail = redact(error.read()[:300].decode("utf-8", "replace"), key)
        print(f"NOT PUBLISHED: upload refused: HTTP {error.code} {detail}")
        return 1
    except (urllib.error.URLError, OSError) as error:
        # Includes timeouts and resets raised directly while reading the response: the server may
        # already have stored the document, so this is neither success nor "not published".
        reason = getattr(error, "reason", error)
        print(f"UNKNOWN: the upload request did not complete ({redact(str(reason), key)}); "
              "it may or may not have been stored. Check the origin before retrying")
        return 6

    previous = body if live is not None else None
    verify_deadline = time.monotonic() + VERIFY_BUDGET
    origin_status, origin_bytes = read_back_origin(
        lambda attempt_deadline: bounded_fetch(origin_url(), key, attempt_deadline),
        raw, previous, deadline=verify_deadline - PUBLIC_READ_RESERVE)
    public_status, public_bytes, headers = bounded_fetch(public_url(), None, verify_deadline)
    message, code = verification_outcome(raw, origin_status, origin_bytes, public_status, public_bytes,
                                         previous)
    print(message)
    if code == 0:
        print(f"public headers: Cache-Control={headers.get('Cache-Control')} ETag={headers.get('ETag')}")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

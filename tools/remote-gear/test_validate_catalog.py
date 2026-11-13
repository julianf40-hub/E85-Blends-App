#!/usr/bin/env python3
"""Tests for the reference catalog validator and seed/bundled parity.

    python3 -m unittest discover -s tools/remote-gear -v
"""

import copy
import json
import pathlib
import re
import time
import unittest

import validate_catalog as v

ROOT = pathlib.Path(__file__).resolve().parents[2]
SEED = ROOT / "docs/remote-gear/catalog-v1.json"
SCHEMA = ROOT / "docs/remote-gear/catalog-v1.schema.json"
SWIFT_VIEW = ROOT / "EightyFiveBlends/RecommendedGearView.swift"


def seed() -> dict:
    return json.loads(SEED.read_text())


def neutral(**overrides) -> dict:
    brand = {
        "id": "new-brand", "kind": "brand", "name": "New Brand", "tagline": "Tools",
        "description": "Product details", "ctaTitle": "View products",
        "destinationURL": "https://example.com/products",
    }
    brand.update(overrides)
    return brand


def doc(*brands, **overrides) -> dict:
    document = {"schemaVersion": 1, "revision": "r1", "publishedAt": 1_800_000_000, "brands": list(brands)}
    document.update(overrides)
    return document


class ValidatorTests(unittest.TestCase):
    def assertRejected(self, document):
        with self.assertRaises(v.Invalid):
            v.validate(document)

    def test_seed_is_publishable(self):
        v.validate_bytes(SEED.read_bytes())

    def test_empty_catalog_is_valid(self):
        self.assertEqual(v.validate(doc()), [])

    def test_unsupported_version(self):
        with self.assertRaises(v.Unsupported):
            v.validate(doc(schemaVersion=2))

    def test_unknown_kind_is_skipped_not_rejected(self):
        warnings = v.validate(doc({"id": "future", "kind": "video_card"}))
        self.assertTrue(any("unknown" in w for w in warnings))

    def test_duplicates_and_ids(self):
        self.assertRejected(doc(neutral(), neutral()))
        self.assertRejected(doc(neutral(id="Bad ID")))
        self.assertRejected(doc({"kind": "video_card"}))

    def test_unsafe_urls(self):
        for url in ["javascript:alert(1)", "http://example.com", "https://user:pw@example.com",
                    "e85blends://open", "https://"]:
            self.assertRejected(doc(neutral(destinationURL=url)))
        self.assertRejected(doc(neutral(heroImageURL="http://cdn.example.com/a.png")))
        self.assertRejected(doc(neutral(logo={"url": "https://a.example/l.png", "darkURL": "ftp://x"})))

    def test_neutral_brand_cannot_claim_sponsorship_or_rvp_identity(self):
        self.assertRejected(doc(neutral(tagline="Our official sponsor")))
        self.assertRejected(doc(neutral(more={"subtitle": "Partner gear"})))
        self.assertRejected(doc(neutral(id=v.RVP_SPONSOR_ID)))
        self.assertRejected(doc(neutral(wheels=[])))
        sponsor = copy.deepcopy(seed()["brands"][1])
        sponsor["id"] = "another-sponsor"
        self.assertRejected(doc(sponsor))

    def test_sponsor_cannot_carry_price_offer_or_remote_branding(self):
        for key, value in [("priceText", "$1"), ("logo", {"url": "https://a.example/l.png"}),
                           ("heroImageURL", "https://a.example/h.png"),
                           ("offer", seed()["brands"][0]["offer"])]:
            sponsor = copy.deepcopy(seed()["brands"][1])
            sponsor[key] = value
            self.assertRejected(doc(sponsor))
        twice = copy.deepcopy(seed()["brands"][1])
        self.assertRejected(doc(twice, copy.deepcopy(twice)))

    def test_new_wheel_requires_remote_image(self):
        sponsor = copy.deepcopy(seed()["brands"][1])
        sponsor["wheels"].append({"id": "new-wheel", "displayName": "New", "accessibilityName": "New wheel",
                                  "productURL": "https://rvpsupply.com/products/new"})
        self.assertRejected(doc(sponsor))
        sponsor["wheels"][-1]["imageURL"] = "https://cdn.example.com/gear/new-wheel-v1.png"
        v.validate(doc(sponsor))

    def test_offer_rules(self):
        offer = {"amountOff": 50, "eligibleProducts": "eligible kits", "code": "SAVE50",
                 "terms": "Terms at checkout.", "disclosure": "We may earn a commission."}
        v.validate(doc(neutral(offer=dict(offer, startsAt=1_800_000_000, expiresAt=1_800_086_400))))
        self.assertRejected(doc(neutral(offer=dict(offer, startsAt=5, expiresAt=5))))
        self.assertRejected(doc(neutral(offer=dict(offer, amountOff=0))))
        self.assertRejected(doc(neutral(offer=dict(offer, amountOff=2.5))))
        self.assertRejected(doc(neutral(offer=dict(offer, code="TWO WORDS"))))
        self.assertRejected(doc(neutral(offer=dict(offer, disclosure=" "))))

    def test_text_limits(self):
        self.assertRejected(doc(neutral(name="x" * 61)))
        self.assertRejected(doc(neutral(priceText="")))
        self.assertRejected(doc(neutral(hidden="yes")))

    def test_size_limit(self):
        with self.assertRaises(v.Invalid):
            v.validate_bytes(b" " * (v.MAXIMUM_BYTES + 1))

    def test_successor_rules(self):
        def raw(document):
            return json.dumps(document, sort_keys=True).encode()
        live = doc(revision="a", publishedAt=200)
        newer = doc(revision="b", publishedAt=201)
        self.assertEqual(v.check_successor(live, raw(live), live, raw(live)), "unchanged")
        self.assertEqual(v.check_successor(live, raw(live), newer, raw(newer)), "newer")
        for candidate in (doc(revision="b", publishedAt=200),       # equal timestamp, different bytes
                          doc(revision="b", publishedAt=100),       # older
                          doc(neutral(), revision="a", publishedAt=300)):  # reused live revision
            with self.assertRaises(v.Invalid):
                v.check_successor(live, raw(live), candidate, raw(candidate))
        reused = doc(revision="old", publishedAt=300)
        with self.assertRaises(v.Invalid):
            v.check_successor(live, raw(live), reused, raw(reused), {"old"})

    def test_withdrawal_cannot_be_undone(self):
        """Mirrors GearCatalogTests.withdrawalCannotBeUndoneByOlderOrEqualTimestampDocuments."""
        def raw(document):
            return json.dumps(document, sort_keys=True).encode()
        withdrawn = doc(revision="withdrawn", publishedAt=2_000)
        for resurrection in (doc(neutral(), revision="with-brand", publishedAt=1_000),
                             doc(neutral(), revision="other", publishedAt=2_000)):
            with self.assertRaises(v.Invalid):
                v.check_successor(withdrawn, raw(withdrawn), resurrection, raw(resurrection), {"with-brand"})

    def test_cli_rollback_flow(self):
        import subprocess, sys, tempfile
        script = pathlib.Path(v.__file__)
        with tempfile.TemporaryDirectory() as tmp:
            def write(name, document):
                path = pathlib.Path(tmp, name)
                path.write_text(json.dumps(document))
                return str(path)
            first = write("r1.json", doc(neutral(), revision="r1", publishedAt=1_000))
            second = write("r2.json", doc(revision="r2", publishedAt=2_000))
            reupload = write("r1-again.json", doc(neutral(), revision="r1", publishedAt=1_000))
            rollback = write("r3.json", doc(neutral(), revision="r3", publishedAt=2_001))

            def run(*args):
                return subprocess.run([sys.executable, "-I", str(script), *args], capture_output=True, text=True)
            self.assertEqual(run("--previous", first, "--previous", second, reupload).returncode, 1)
            self.assertEqual(run("--previous", first, "--previous", second, rollback).returncode, 0)
            same = run("--previous", second, second)
            self.assertEqual(same.returncode, 0)
            self.assertIn("unchanged", same.stdout)


class StagingFixtureTests(unittest.TestCase):
    """make_fixtures.py: every fixture is publishable and the sequence is correctly ordered."""

    def test_fixture_sequence_is_valid_and_ordered(self):
        import make_fixtures
        documents = make_fixtures.build(now=1_800_000_000)
        self.assertGreaterEqual(len(documents), 8)
        previous = None
        used = set()
        for name, _, document in documents:
            raw = json.dumps(document).encode()
            v.validate_bytes(raw)
            if previous is not None:
                self.assertEqual(v.check_successor(previous[0], previous[1], document, raw, used), "newer", name)
            used.add(document["revision"])
            previous = (document, raw)
        names = [name for name, _, _ in documents]
        empty = dict((n, d) for n, _, d in documents)["08-empty"]
        self.assertEqual(empty["brands"], [])
        self.assertIn("09-rollback-to-parity", names)

    def test_fixtures_use_only_fictional_new_brand_and_unchanged_partner_copy(self):
        import make_fixtures
        seed_brands = {b["id"]: b for b in seed()["brands"]}
        for _, _, document in make_fixtures.build(now=1_800_000_000):
            for brand in document["brands"]:
                if brand["id"] in seed_brands:
                    original = seed_brands[brand["id"]]
                    for key in ("name", "tagline", "description", "ctaTitle", "destinationURL", "offer"):
                        self.assertEqual(brand.get(key), original.get(key), f"{brand['id']} {key} must not change")
                else:
                    self.assertEqual(brand["id"], "example-fuel-tools")
                    self.assertTrue(brand["destinationURL"].startswith("https://example.com/"))


class StagingPublisherTests(unittest.TestCase):
    """publish_catalog.py decisions, offline (no network, no key)."""

    def setUp(self):
        import publish_catalog
        self.p = publish_catalog
        self.a = str(ROOT / "docs/remote-gear/staging/publication-a.json")
        self.b = str(ROOT / "docs/remote-gear/staging/publication-b.json")
        self.missing_object = (400, b'{"statusCode":"404","error":"not_found","message":"Object not found"}')
        self.missing_bucket = (400, b'{"statusCode":"404","error":"Bucket not found","message":"Bucket not found","code":"NoSuchBucket"}')

    def test_urls_are_storage_not_postgrest(self):
        self.assertEqual(self.p.public_url(),
                         "https://zefkbtscieokkdenvnkg.supabase.co/storage/v1/object/public/recommended-gear/staging/catalog-v1.json")
        self.assertNotIn("/rest/v1/", self.p.upload_url())

    def test_missing_bucket_stops_but_missing_object_is_a_first_publication(self):
        with self.assertRaises(self.p.PublishError):
            self.p.classify_live_response(*self.missing_bucket)
        self.assertEqual(self.p.classify_live_response(*self.missing_object), "absent")
        with self.assertRaises(self.p.PublishError):
            self.p.classify_live_response(500, b"oops")

    def test_publication_a_then_b_is_a_valid_ordered_succession(self):
        doc_a, raw_a, live = self.p.prepare(self.a, *self.missing_object, now=1_800_000_000.7)
        self.assertIsNone(live)
        self.assertEqual(doc_a["publishedAt"], 1_800_000_000)
        doc_b, raw_b, live = self.p.prepare(self.b, 200, raw_a, now=1_800_000_000.9)  # same second
        self.assertEqual(live["revision"], doc_a["revision"])
        self.assertEqual(doc_b["publishedAt"], 1_800_000_001, "rapid successive publishes still increase")
        self.assertNotEqual(doc_b["revision"], doc_a["revision"])
        b_ids = [brand["id"] for brand in doc_b["brands"]]
        self.assertEqual(b_ids, ["example-fuel-tools"], "B removes the sensor kit")
        self.assertEqual(doc_b["brands"][0]["priceText"], "From $39")
        self.assertEqual(doc_b["brands"][0]["destinationURL"], "https://example.com/fuel-tools-v2")

    def test_live_clock_ahead_still_increases(self):
        doc_a, raw_a, _ = self.p.prepare(self.a, *self.missing_object, now=1_800_000_120)
        doc_b, _, _ = self.p.prepare(self.b, 200, raw_a, now=1_800_000_000)  # local clock 2 min behind
        self.assertEqual(doc_b["publishedAt"], 1_800_000_121, "still strictly newer than the live one")

    def test_uploads_read_the_origin_not_the_cdn(self):
        self.assertIn("/object/authenticated/", self.p.origin_url())
        self.assertNotIn("/public/", self.p.origin_url())

    def test_future_live_clock_is_refused(self):
        doc_a, raw_a, _ = self.p.prepare(self.a, *self.missing_object, now=2_000_000_000)
        with self.assertRaises(self.p.PublishError):
            self.p.prepare(self.b, 200, raw_a, now=2_000_000_000 - 301)

    def test_verification_never_reports_a_successful_upload_as_unpublished(self):
        ours, other = b"ours", b"theirs"
        message, code = self.p.verification_outcome(ours, 200, ours, 200, ours)
        self.assertEqual(code, 0)
        message, code = self.p.verification_outcome(ours, 200, ours, 200, other)  # CDN lag
        self.assertEqual(code, 3)
        self.assertTrue(message.startswith("PUBLISHED"))
        message, code = self.p.verification_outcome(ours, 200, other, 200, other)  # replaced
        self.assertEqual(code, 4)
        self.assertIn("CONFLICT", message)
        message, code = self.p.verification_outcome(ours, 500, b"", 200, ours)
        self.assertEqual(code, 5)
        self.assertTrue(message.startswith("UPLOADED"))
        for code_message in (self.p.verification_outcome(ours, 200, ours, 404, b""),):
            self.assertNotIn("NOT PUBLISHED", code_message[0])

    def _via_fetch(self, url, key=None, deadline=None, clock=None):
        """Stand-in for bounded_fetch in mock-based tests: the same GET through the mocked urlopen."""
        return self.p.fetch(url, key)

    def readback(self, responses, ours, previous):
        """read_back_origin over scripted origin responses; returns (status, body, fetch count)."""
        replies, waits = list(responses), []
        def fetch_origin(attempt_deadline):
            status, body = replies.pop(0) if replies else responses[-1]
            return status, body, {}
        status, body = self.p.read_back_origin(fetch_origin, ours, previous,
                                               deadline=time.monotonic() + 1000, sleep=waits.append)
        return status, body, len(waits)

    def test_stale_origin_then_ours_is_published_not_conflict(self):
        ours, previous = b"ours", b"previous"
        status, body, fetches = self.readback([(200, previous), (200, previous), (200, ours)], ours, previous)
        self.assertEqual((status, body, fetches), (200, ours, 3))
        message, code = self.p.verification_outcome(ours, status, body, 200, ours, previous)
        self.assertEqual(code, 0)

    def test_origin_stale_throughout_is_unconfirmed_not_conflict(self):
        ours, previous = b"ours", b"previous"
        status, body, fetches = self.readback([(200, previous)], ours, previous)
        self.assertEqual(fetches, len(self.p.READBACK_DELAYS), "retried every attempt")
        self.assertLessEqual(sum(self.p.READBACK_DELAYS), 15, "bounded wait")
        message, code = self.p.verification_outcome(ours, status, body, 200, previous, previous)
        self.assertEqual(code, 7)
        self.assertTrue(message.startswith("UPLOADED"))
        self.assertNotIn("CONFLICT", message)

    def test_third_document_is_conflict_without_waiting(self):
        ours, previous, theirs = b"ours", b"previous", b"theirs"
        status, body, fetches = self.readback([(200, theirs)], ours, previous)
        self.assertEqual((body, fetches), (theirs, 1))
        message, code = self.p.verification_outcome(ours, status, body, 200, theirs, previous)
        self.assertEqual(code, 4)
        self.assertIn("CONFLICT", message)

    def test_failed_origin_reads_are_retried(self):
        ours, previous = b"ours", b"previous"
        status, body, fetches = self.readback([(0, b"reset"), (503, b""), (200, ours)], ours, previous)
        self.assertEqual((status, body, fetches), (200, ours, 3))
        status, _, _ = self.readback([(0, b"reset")], ours, previous)
        self.assertEqual(self.p.verification_outcome(ours, status, b"", 200, ours, previous)[1], 5)

    def test_read_back_attempts_and_waits_stay_within_the_deadline(self):
        now = [0.0]
        allowances = []
        def fetch_origin(attempt_deadline):  # every read hangs until its own deadline, then fails
            allowances.append(attempt_deadline - now[0])
            now[0] = attempt_deadline
            return 0, self.p.DEADLINE_EXCEEDED, {}
        def sleep(seconds):
            now[0] += seconds
        status, _ = self.p.read_back_origin(fetch_origin, b"ours", b"previous", deadline=20.0,
                                            sleep=sleep, clock=lambda: now[0])
        self.assertEqual(status, 0)
        self.assertLessEqual(now[0], 20.0, "attempts + waits stay within the deadline")
        self.assertTrue(all(0 < a <= self.p.READBACK_REQUEST_TIMEOUT for a in allowances))
        self.assertGreaterEqual(len(allowances), 2, "a hanging read still leaves time to retry")

    def test_matching_requires_exact_bytes_not_just_the_revision(self):
        ours = self.p.encode({"revision": "r1", "publishedAt": 5, "brands": []})
        same_revision = self.p.encode({"revision": "r1", "publishedAt": 5, "brands": [{"id": "x"}]})
        status, body, _ = self.readback([(200, same_revision)], ours, b"previous")
        message, code = self.p.verification_outcome(ours, status, body, 200, same_revision, b"previous")
        self.assertEqual(code, 4)

    def test_exhausted_reads_name_missing_object_and_transport_failure_apart(self):
        ours, previous = b"ours", b"previous"
        missing = b'{"statusCode":"404","error":"not_found","message":"Object not found","code":"NoSuchKey"}'
        status, body, fetches = self.readback([(400, missing)], ours, previous)
        self.assertEqual(fetches, len(self.p.READBACK_DELAYS))
        message, code = self.p.verification_outcome(ours, status, body, 200, ours, previous)
        self.assertEqual(code, 5)
        self.assertIn("no object", message)
        message, code = self.p.verification_outcome(ours, 0, b"reset", 200, ours, previous)
        self.assertEqual(code, 5)
        self.assertIn("could not connect", message)
        self.assertNotIn("no object", message)
        message, code = self.p.verification_outcome(ours, 200, previous, 200, previous, previous)
        self.assertEqual(code, 7)

    def test_conflict_reports_observed_content_without_claiming_a_publisher(self):
        message, code = self.p.verification_outcome(b"ours", 200, b"theirs", 200, b"theirs", b"previous")
        self.assertEqual(code, 4)
        self.assertIn("neither our upload nor", message)
        self.assertNotIn("replaced ours", message)

    def test_key_is_never_printed_on_any_upload_error_path(self):
        import contextlib, io, os, unittest.mock, urllib.error
        key = "eyJ-test-service-role-never-print"
        echo = f'{{"message":"bad token {key}"}}'.encode()

        def run(script):
            calls = list(script)
            def fake_urlopen(request, timeout=None):
                outcome = calls.pop(0) if calls else calls_tail[0]
                if isinstance(outcome, BaseException):
                    raise outcome
                status, body = outcome
                if status != 200:
                    raise urllib.error.HTTPError(request.full_url, status, "error", {}, io.BytesIO(body))
                response = unittest.mock.MagicMock()
                response.__enter__.return_value.status = status
                response.__enter__.return_value.read.return_value = body
                response.__enter__.return_value.headers = {}
                return response
            calls_tail = [script[-1]]
            out = io.StringIO()
            with unittest.mock.patch.dict(os.environ, {"SUPABASE_SERVICE_ROLE_KEY": key}), \
                 unittest.mock.patch.object(self.p.urllib.request, "urlopen", side_effect=fake_urlopen), \
                 unittest.mock.patch.object(self.p.time, "sleep"), \
                 unittest.mock.patch.object(self.p, "bounded_fetch", side_effect=self._via_fetch), \
                 contextlib.redirect_stdout(out):
                code = self.p.main([self.a, "--upload"])
            return code, out.getvalue()

        paths = {
            "live read refused": [(403, echo)],
            "live read transport": [urllib.error.URLError(f"reset {key}")],
            "upload refused": [self.missing_object, (403, echo)],
            "upload transport": [self.missing_object, urllib.error.URLError(f"reset {key}")],
            "origin read-back refused": [self.missing_object, (200, b"{}"), (403, echo)],
            "origin read-back transport": [self.missing_object, (200, b"{}"), urllib.error.URLError(f"reset {key}")],
            "conflict": [self.missing_object, (200, b"{}"), (200, echo)],
        }
        for name, script in paths.items():
            with self.subTest(name):
                code, output = run(script)
                self.assertNotEqual(code, 0)
                self.assertNotIn(key, output)

    def test_first_publication_has_no_previous_to_mistake_for_staleness(self):
        ours, theirs = b"ours", b"theirs"
        status, body, fetches = self.readback([(200, theirs)], ours, None)
        self.assertEqual(fetches, 1)
        self.assertEqual(self.p.verification_outcome(ours, status, body, 200, theirs, None)[1], 4)

    def test_secret_key_is_sent_only_as_apikey_and_legacy_jwt_keeps_bearer(self):
        self.assertEqual(self.p.auth_headers("sb_secret_abc"), {"apikey": "sb_secret_abc"})
        self.assertEqual(self.p.auth_headers("eyJlegacy"),
                         {"apikey": "eyJlegacy", "Authorization": "Bearer eyJlegacy"})
        for wrong in ("sb_publishable_abc", "random-token"):
            with self.assertRaises(self.p.PublishError) as raised:
                self.p.auth_headers(wrong)
            self.assertNotIn(wrong, str(raised.exception))

    def test_secret_key_variable_takes_precedence_over_legacy_name(self):
        self.assertEqual(self.p.read_key({"SUPABASE_SECRET_KEY": " sb_secret_new ",
                                          "SUPABASE_SERVICE_ROLE_KEY": "eyJold"}),
                         ("sb_secret_new", "SUPABASE_SECRET_KEY"))
        self.assertEqual(self.p.read_key({"SUPABASE_SERVICE_ROLE_KEY": "eyJold"}),
                         ("eyJold", "SUPABASE_SERVICE_ROLE_KEY"))
        self.assertEqual(self.p.read_key({}), (None, None))

    def _run_with_key(self, env, argv, statuses):
        """main() with `env` and scripted GET statuses; returns (code, output, requests seen)."""
        import contextlib, io, os, unittest.mock, urllib.error
        seen, replies = [], list(statuses)
        def fake_urlopen(request, timeout=None):
            seen.append(request)
            if request.get_method() == "POST":
                response = unittest.mock.MagicMock()
                response.__enter__.return_value.status = 200
                return response
            status, body = replies.pop(0) if replies else statuses[-1]
            if status != 200:
                raise urllib.error.HTTPError(request.full_url, status, "error", {}, io.BytesIO(body))
            response = unittest.mock.MagicMock()
            response.__enter__.return_value.status = 200
            response.__enter__.return_value.read.return_value = body
            response.__enter__.return_value.headers = {}
            return response
        clean = {k: v for k, v in os.environ.items() if k not in self.p.KEY_ENV_VARS}
        out = io.StringIO()
        with unittest.mock.patch.dict(os.environ, {**clean, **env}, clear=True), \
             unittest.mock.patch.object(self.p.urllib.request, "urlopen", side_effect=fake_urlopen), \
             unittest.mock.patch.object(self.p.time, "sleep"), \
             unittest.mock.patch.object(self.p, "bounded_fetch", side_effect=self._via_fetch), \
             contextlib.redirect_stdout(out):
            code = self.p.main(argv)
        return code, out.getvalue(), seen

    def test_upload_with_secret_key_never_sends_it_as_bearer(self):
        key = "sb_secret_upload-test-key"
        code, output, seen = self._run_with_key({"SUPABASE_SECRET_KEY": key}, [self.a, "--upload"],
                                                [self.missing_object, (200, b"not ours")])
        self.assertTrue(seen, "requests were made")
        for request in seen:
            self.assertIsNone(request.get_header("Authorization"), request.get_method())
            if "/object/public/" in request.full_url:
                self.assertIsNone(request.get_header("Apikey"), "public reads carry no credentials")
            else:
                self.assertEqual(request.get_header("Apikey"), key, request.full_url)
        self.assertIn("POST", [r.get_method() for r in seen])
        self.assertNotIn(key, output)

    def test_publishable_key_is_refused_before_any_request(self):
        key = "sb_publishable_should-not-write"
        for argv in ([self.a, "--upload"], [self.a, "--verify-key"]):
            code, output, seen = self._run_with_key({"SUPABASE_SECRET_KEY": key}, argv, [(200, b"{}")])
            self.assertEqual((code, seen), (1, []))
            self.assertIn("publishable", output)
            self.assertNotIn(key, output)

    def test_verify_key_reads_origin_only_and_reports_acceptance(self):
        key = "sb_secret_verify-test-key"
        missing = self.missing_object
        for statuses, expected in (([(200, b"{}")], 0), ([missing], 0), ([(401, b"")], 1),
                                   ([(403, b'{"message":"Invalid Compact JWS"}')], 1)):
            code, output, seen = self._run_with_key({"SUPABASE_SECRET_KEY": key},
                                                    [self.a, "--verify-key"], statuses)
            with self.subTest(statuses=statuses[0][0]):
                self.assertEqual(code, expected)
                self.assertEqual([r.get_method() for r in seen], ["GET"], "one read, never an upload")
                self.assertIn("/object/authenticated/", seen[0].full_url)
                self.assertIn("accepted" if expected == 0 else "NOT accepted", output)
                self.assertNotIn(key, output)

    def test_key_is_redacted_from_printed_server_text(self):
        key = "service-role-secret-value"
        self.assertEqual(self.p.redact(f"error near {key} here", key), "error near <redacted> here")
        self.assertEqual(self.p.redact("no secret", None), "no secret")

    def test_key_never_appears_in_dry_run_output_or_written_document(self):
        import contextlib, io, os, tempfile, unittest.mock
        key = "sk-test-should-never-be-printed"
        out = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp, unittest.mock.patch.dict(os.environ, {"SUPABASE_SERVICE_ROLE_KEY": key}), \
             unittest.mock.patch.object(self.p, "fetch", return_value=(*self.missing_object, {})), \
             contextlib.redirect_stdout(out):
            written = pathlib.Path(tmp, "stamped.json")
            code = self.p.main([self.a, "--out", str(written)])
            self.assertEqual(code, 0)
            self.assertNotIn(key, written.read_text())
        self.assertNotIn(key, out.getvalue())

    def _run_upload(self, read_backs):
        """main --upload with a successful upload; `read_backs` are the origin and public fetch results."""
        import contextlib, io, os, unittest.mock, urllib.error
        responses = [(*self.missing_object, {})] + list(read_backs)

        def fake_urlopen(request, timeout=None):
            if request.get_method() == "POST":
                response = unittest.mock.MagicMock()
                response.__enter__.return_value.status = 200
                return response
            outcome = responses.pop(0)
            if isinstance(outcome, BaseException):
                raise outcome
            status, body, headers = outcome
            if status != 200:
                raise urllib.error.HTTPError(request.full_url, status, "error", headers, io.BytesIO(body))
            response = unittest.mock.MagicMock()
            response.__enter__.return_value.status = status
            response.__enter__.return_value.read.return_value = body
            response.__enter__.return_value.headers = headers
            return response

        out = io.StringIO()
        with unittest.mock.patch.dict(os.environ, {"SUPABASE_SERVICE_ROLE_KEY": "sb_secret_test"}), \
             unittest.mock.patch.object(self.p.urllib.request, "urlopen", side_effect=fake_urlopen), \
             unittest.mock.patch.object(self.p.time, "sleep"), \
             unittest.mock.patch.object(self.p, "bounded_fetch", side_effect=self._via_fetch), \
             contextlib.redirect_stdout(out):
            code = self.p.main([self.a, "--upload"])
        return code, out.getvalue()

    def test_origin_read_back_transport_failure_reports_uploaded_unverified(self):
        import urllib.error
        failures = [urllib.error.URLError("connection reset")] * len(self.p.READBACK_DELAYS)
        code, output = self._run_upload([*failures, (200, b"x", {})])
        self.assertEqual(code, 5)
        self.assertIn("UPLOADED", output)
        self.assertNotIn("NOT PUBLISHED", output)

    def test_public_read_back_transport_failure_keeps_the_origin_verification(self):
        import urllib.error
        captured = {}
        real_encode = self.p.encode
        def capture(document):
            captured["raw"] = real_encode(document)
            return captured["raw"]
        import unittest.mock
        with unittest.mock.patch.object(self.p, "encode", side_effect=capture):
            code, output = self._run_upload_with_echo(captured, urllib.error.URLError("timed out"))
        self.assertEqual(code, 3)
        self.assertIn("PUBLISHED (origin verified)", output)

    def _run_upload_with_echo(self, captured, public_failure):
        import contextlib, io, os, unittest.mock
        calls = {"get": 0}

        def fake_urlopen(request, timeout=None):
            if request.get_method() == "POST":
                response = unittest.mock.MagicMock()
                response.__enter__.return_value.status = 200
                return response
            calls["get"] += 1
            if calls["get"] == 1:  # live read before upload: nothing published yet
                import urllib.error
                raise urllib.error.HTTPError(request.full_url, 400, "error", {}, io.BytesIO(self.missing_object[1]))
            if calls["get"] == 2:  # origin read-back: our bytes
                response = unittest.mock.MagicMock()
                response.__enter__.return_value.status = 200
                response.__enter__.return_value.read.return_value = captured["raw"]
                response.__enter__.return_value.headers = {}
                return response
            raise public_failure  # public read-back: transport failure

        out = io.StringIO()
        with unittest.mock.patch.dict(os.environ, {"SUPABASE_SERVICE_ROLE_KEY": "sb_secret_test"}), \
             unittest.mock.patch.object(self.p.urllib.request, "urlopen", side_effect=fake_urlopen), \
             unittest.mock.patch.object(self.p, "bounded_fetch", side_effect=self._via_fetch), \
             contextlib.redirect_stdout(out):
            code = self.p.main([self.a, "--upload"])
        return code, out.getvalue()

    def test_upload_transport_failure_is_an_unknown_outcome(self):
        """The server may already have accepted the write, so none of these may read as
        success or as "not published", and none may escape as a traceback."""
        import contextlib, io, os, unittest.mock, urllib.error
        for failure in (urllib.error.URLError("connection reset"), TimeoutError("read timed out"),
                        ConnectionResetError(54, "reset by peer")):
            def fake_urlopen(request, timeout=None, failure=failure):
                if request.get_method() == "POST":
                    raise failure
                raise urllib.error.HTTPError(request.full_url, 400, "error", {}, io.BytesIO(self.missing_object[1]))
            out = io.StringIO()
            with unittest.mock.patch.dict(os.environ, {"SUPABASE_SERVICE_ROLE_KEY": "sb_secret_test-secret"}), \
                 unittest.mock.patch.object(self.p.urllib.request, "urlopen", side_effect=fake_urlopen), \
                 contextlib.redirect_stdout(out):
                code = self.p.main([self.a, "--upload"])
            with self.subTest(failure=type(failure).__name__):
                self.assertEqual(code, 6)
                self.assertIn("UNKNOWN", out.getvalue())
                self.assertNotIn("NOT PUBLISHED", out.getvalue())
                self.assertNotIn("sb_secret_test-secret", out.getvalue())

    def test_pre_upload_transport_failure_stops_without_a_traceback(self):
        import contextlib, io, unittest.mock, urllib.error
        out = io.StringIO()
        with unittest.mock.patch.object(self.p.urllib.request, "urlopen", side_effect=urllib.error.URLError("offline")), \
             contextlib.redirect_stdout(out):
            code = self.p.main([self.a])
        self.assertEqual(code, 1)
        self.assertIn("STOPPED", out.getvalue())

    def test_templates_use_only_fictional_brands_and_example_domains(self):
        for path in (self.a, self.b):
            document = json.loads(pathlib.Path(path).read_text())
            for brand in document["brands"]:
                self.assertTrue(brand["id"].startswith("example-"))
                self.assertEqual(brand["kind"], "brand")
                self.assertTrue(brand["destinationURL"].startswith("https://example.com/"))


class SeedParityTests(unittest.TestCase):
    """The seed must describe exactly what the app bundles, so first publication changes nothing."""

    def setUp(self):
        self.swift = SWIFT_VIEW.read_text()
        self.seed = seed()

    def swift_string(self, label, after):
        start = self.swift.index(after)
        match = re.compile(label + r':\s*"([^"]*)"').search(self.swift, start)
        return match.group(1)

    def test_wheels_match_bundled_catalog(self):
        bundled = re.findall(
            r'RVPWheelProduct\(\s*id: "([^"]+)",\s*displayName: "([^"]+)",\s*assetName: "[^"]+",\s*'
            r'productURL: URL\(string: "([^"]+)"\),\s*accessibilityName: "([^"]+)"', self.swift)
        self.assertEqual(len(bundled), 9)
        wheels = [(w["id"], w["displayName"], w["productURL"], w["accessibilityName"])
                  for w in self.seed["brands"][1]["wheels"]]
        self.assertEqual(wheels, bundled)
        self.assertEqual({w[0] for w in bundled}, v.BUNDLED_WHEEL_IDS)

    def test_brand_copy_matches_bundled_catalog(self):
        ef, rvp = self.seed["brands"]
        for key in ("name", "tagline", "description", "ctaTitle"):
            self.assertEqual(ef[key], self.swift_string(key, "static let eFlexFuel = FeaturedBrand("))
            self.assertEqual(rvp[key], self.swift_string(key, "static let rvpSupplyWheels = FeaturedBrand("))
        offer = ef["offer"]
        for key in ("eligibleProducts", "code", "terms", "disclosure"):
            self.assertEqual(offer[key], self.swift_string(key, "static let eFlexFuel = FeaturedOffer("))
        self.assertNotIn("expiresAt", offer, "the approved eFlexFuel copy names no expiry")

    def test_destinations_match_bundled_catalog(self):
        ef, rvp = self.seed["brands"]
        self.assertIn(f'URL(string: "{ef["destinationURL"]}")', self.swift)
        for key, name in [("homepageURL", "homepage"), ("configuratorURL", "configurator"),
                          ("destinationURL", "wheelsCollection")]:
            self.assertIn(f'static let {name} = URL(string: "{rvp[key]}")', self.swift)
        self.assertEqual(rvp["more"]["subtitle"], "Performance parts & gear")

    def test_schema_file_is_valid_json_and_lists_kinds(self):
        schema = json.loads(SCHEMA.read_text())
        self.assertEqual(schema["properties"]["schemaVersion"]["const"], 1)


class PublisherDeadlineServerTests(unittest.TestCase):
    """main --upload against a REAL local HTTP server that stalls verification reads by trickling
    bytes (headers, success body, error body). The deadline must hold anyway, the stalled
    connections must be closed, the upload must happen exactly once, the outcome must be reported
    as uncertain, and the key must never be printed."""

    KEY = "eyJ-local-trickle-test-key-never-print"
    BUDGET, RESERVE, ATTEMPT = 1.6, 0.6, 0.5
    TOLERANCE = 1.5  # scheduling slack on a loaded machine; the budget itself is 1.6 s
    MISSING = b'{"statusCode":"404","error":"not_found","message":"Object not found","code":"NoSuchKey"}'

    def setUp(self):
        import http.server, threading
        import publish_catalog
        self.p = publish_catalog
        test = self
        self.lock = threading.Lock()
        self.uploads, self.stored, self.origin_gets = 0, None, 0
        self.requests = []  # (method, path, apikey header, Authorization header)
        self.env = {"SUPABASE_SERVICE_ROLE_KEY": self.KEY}
        self.trickles_started, self.trickles_closed = 0, 0
        self.origin_mode, self.public_mode = "fast-ours", "fast-ours"
        self.stopping = threading.Event()

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_POST(self):
                test.requests.append(("POST", self.path, self.headers.get("apikey"), self.headers.get("Authorization")))
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                with test.lock:
                    test.uploads += 1
                    test.stored = body
                self._send(200, b'{"Key":"recommended-gear/staging/catalog-v1.json"}')

            def do_GET(self):
                test.requests.append(("GET", self.path, self.headers.get("apikey"), self.headers.get("Authorization")))
                if "/object/authenticated/" in self.path:
                    with test.lock:
                        test.origin_gets += 1
                        first = test.origin_gets == 1
                    mode = "fast-missing" if first else test.origin_mode  # first GET: live read
                else:
                    mode = test.public_mode
                if mode == "fast-ours":
                    self._send(200, test.stored or b"")
                elif mode == "fast-missing":
                    self._send(400, test.MISSING)
                elif mode == "trickle-200":
                    self._trickle(b"HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\n", b"x")
                elif mode == "trickle-503":
                    head = b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 100000\r\n\r\n"
                    self._trickle(head + f'{{"message":"slow error {test.KEY}"'.encode(), b" ")
                elif mode == "trickle-headers":
                    self._trickle(b"HTTP/1.1 200 OK\r\nX-Slow: ", b"a")

            def _send(self, status, body):
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _trickle(self, prefix, unit):
                import time as clock
                with test.lock:
                    test.trickles_started += 1
                try:
                    self.wfile.write(prefix)
                    self.wfile.flush()
                    end = clock.monotonic() + 20
                    while clock.monotonic() < end and not test.stopping.is_set():
                        clock.sleep(0.05)
                        self.wfile.write(unit)
                        self.wfile.flush()
                except OSError:  # the publisher closed the connection
                    with test.lock:
                        test.trickles_closed += 1
                self.close_connection = True

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        self.stopping.set()
        self.server.shutdown()
        self.server.server_close()

    def run_upload(self):
        import contextlib, io, os, time as clock, unittest.mock
        p, base, path = self.p, self.base, f"{self.p.BUCKET}/{self.p.STAGING_PATH}"
        out = io.StringIO()
        clean = {k: v for k, v in os.environ.items() if k not in p.KEY_ENV_VARS}
        with unittest.mock.patch.dict(os.environ, {**clean, **self.env}, clear=True), \
             unittest.mock.patch.object(p, "origin_url", lambda: f"{base}/storage/v1/object/authenticated/{path}"), \
             unittest.mock.patch.object(p, "public_url", lambda: f"{base}/storage/v1/object/public/{path}"), \
             unittest.mock.patch.object(p, "upload_url", lambda: f"{base}/storage/v1/object/{path}"), \
             unittest.mock.patch.object(p, "VERIFY_BUDGET", self.BUDGET), \
             unittest.mock.patch.object(p, "PUBLIC_READ_RESERVE", self.RESERVE), \
             unittest.mock.patch.object(p, "READBACK_REQUEST_TIMEOUT", self.ATTEMPT), \
             unittest.mock.patch.object(p, "READBACK_DELAYS", (0, 0.05, 0.05, 0.05)), \
             contextlib.redirect_stdout(out):
            start = clock.monotonic()
            code = p.main([str(ROOT / "docs/remote-gear/staging/publication-a.json"), "--upload"])
            elapsed = clock.monotonic() - start
        return code, out.getvalue(), elapsed

    def assert_bounded_and_closed(self, elapsed, output):
        import threading, time as clock
        self.assertLessEqual(elapsed, self.BUDGET + self.TOLERANCE, f"took {elapsed:.2f} s")
        self.assertEqual(self.uploads, 1, "exactly one upload; retries are reads only")
        self.assertNotIn(self.KEY, output)
        self.assertGreaterEqual(self.trickles_started, 1, "the stalling path was exercised")
        settle = clock.monotonic() + 3
        while clock.monotonic() < settle:
            with self.lock:
                closed = self.trickles_closed == self.trickles_started
            workers = [t for t in threading.enumerate() if t.name == "publisher-bounded-fetch" and t.is_alive()]
            if closed and not workers:
                break
            clock.sleep(0.05)
        self.assertEqual(self.trickles_closed, self.trickles_started, "every stalled connection was closed")
        self.assertEqual(workers, [], "no read is still running after the deadline")

    def test_trickling_success_body_is_cut_off_and_reported_unconfirmed(self):
        self.origin_mode, self.public_mode = "trickle-200", "fast-missing"
        code, output, elapsed = self.run_upload()
        self.assertEqual(code, 5, output)
        self.assertIn("UPLOADED, but the origin read-back failed after retrying (timed out", output)
        self.assertNotIn("NOT PUBLISHED", output)
        self.assert_bounded_and_closed(elapsed, output)
        self.assertGreaterEqual(self.origin_gets - 1, 2, "a stalled attempt still leaves time to retry")

    def test_trickling_error_body_is_cut_off_and_reported_unconfirmed(self):
        self.origin_mode, self.public_mode = "trickle-503", "fast-missing"
        code, output, elapsed = self.run_upload()
        self.assertEqual(code, 5, output)
        self.assertIn("(timed out", output)
        self.assert_bounded_and_closed(elapsed, output)

    def test_trickling_headers_are_cut_off_and_reported_unconfirmed(self):
        self.origin_mode, self.public_mode = "trickle-headers", "fast-missing"
        code, output, elapsed = self.run_upload()
        self.assertEqual(code, 5, output)
        self.assertIn("(timed out", output)
        self.assert_bounded_and_closed(elapsed, output)

    def test_trickling_public_read_keeps_the_origin_verification(self):
        self.origin_mode, self.public_mode = "fast-ours", "trickle-200"
        code, output, elapsed = self.run_upload()
        self.assertEqual(code, 3, output)
        self.assertIn("PUBLISHED (origin verified)", output)
        self.assertIn("timed out", output)
        self.assert_bounded_and_closed(elapsed, output)

    def test_secret_key_is_sent_only_as_apikey_on_every_privileged_request(self):
        key = "sb_secret_local-header-test-key"
        self.env = {"SUPABASE_SECRET_KEY": key}
        self.origin_mode, self.public_mode = "fast-ours", "fast-ours"
        code, output, _ = self.run_upload()
        self.assertEqual(code, 0, output)
        self.assertEqual(self.uploads, 1)
        privileged = [r for r in self.requests if "/object/public/" not in r[1]]
        public = [r for r in self.requests if "/object/public/" in r[1]]
        self.assertGreaterEqual(len(privileged), 3, "live read, upload, origin read-back")
        for method, path, apikey, authorization in privileged:
            self.assertEqual(apikey, key, f"{method} {path}")
            self.assertIsNone(authorization, f"{method} {path}: a secret key is never a Bearer token")
        for method, path, apikey, authorization in public:
            self.assertEqual((apikey, authorization), (None, None), "public reads carry no credentials")
        self.assertNotIn(key, output)

    def test_fast_responses_pass_through_unchanged(self):
        import time as clock
        self.stored, self.origin_gets = b'{"ok":true}', 1  # past the live read
        url = f"{self.base}/storage/v1/object/authenticated/x"
        status, body, headers = self.p.bounded_fetch(url, self.KEY, clock.monotonic() + 2)
        self.assertEqual((status, body), (200, b'{"ok":true}'))
        self.origin_mode = "fast-missing"
        status, body, _ = self.p.bounded_fetch(url, None, clock.monotonic() + 2)
        self.assertEqual((status, body), (400, self.MISSING))


if __name__ == "__main__":
    unittest.main()

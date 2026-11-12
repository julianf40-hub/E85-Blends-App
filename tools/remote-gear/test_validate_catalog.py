#!/usr/bin/env python3
"""Tests for the reference catalog validator and seed/bundled parity.

    python3 -m unittest discover -s tools/remote-gear -v
"""

import copy
import json
import pathlib
import re
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
        with unittest.mock.patch.dict(os.environ, {"SUPABASE_SERVICE_ROLE_KEY": "sk-test"}), \
             unittest.mock.patch.object(self.p.urllib.request, "urlopen", side_effect=fake_urlopen), \
             contextlib.redirect_stdout(out):
            code = self.p.main([self.a, "--upload"])
        return code, out.getvalue()

    def test_origin_read_back_transport_failure_reports_uploaded_unverified(self):
        import urllib.error
        code, output = self._run_upload([urllib.error.URLError("connection reset"), (200, b"x", {})])
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
        with unittest.mock.patch.dict(os.environ, {"SUPABASE_SERVICE_ROLE_KEY": "sk-test"}), \
             unittest.mock.patch.object(self.p.urllib.request, "urlopen", side_effect=fake_urlopen), \
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
            with unittest.mock.patch.dict(os.environ, {"SUPABASE_SERVICE_ROLE_KEY": "sk-test-secret"}), \
                 unittest.mock.patch.object(self.p.urllib.request, "urlopen", side_effect=fake_urlopen), \
                 contextlib.redirect_stdout(out):
                code = self.p.main([self.a, "--upload"])
            with self.subTest(failure=type(failure).__name__):
                self.assertEqual(code, 6)
                self.assertIn("UNKNOWN", out.getvalue())
                self.assertNotIn("NOT PUBLISHED", out.getvalue())
                self.assertNotIn("sk-test-secret", out.getvalue())

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


if __name__ == "__main__":
    unittest.main()

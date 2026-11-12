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
        live = doc(revision="a", publishedAt=200)
        v.check_successor(live, doc(revision="b", publishedAt=200))
        with self.assertRaises(v.Invalid):
            v.check_successor(live, doc(revision="b", publishedAt=100))
        with self.assertRaises(v.Invalid):
            v.check_successor(live, doc(revision="a", publishedAt=300))


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

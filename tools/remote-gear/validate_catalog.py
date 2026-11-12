#!/usr/bin/env python3
"""Reference validator for the Recommended Gear catalog, schema version 1.

Mirrors the acceptance rules in EightyFiveBlends/GearCatalog.swift so the publishing dashboard,
the Android client and CI can reject a document BEFORE it is published (a document the apps reject
is simply ignored by them, which leaves devices on the previous publication).

    python3 tools/remote-gear/validate_catalog.py docs/remote-gear/catalog-v1.json
    python3 tools/remote-gear/validate_catalog.py --previous live.json candidate.json

Exit status 0 = publishable. Uses only the Python standard library.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from urllib.parse import urlsplit

SUPPORTED_SCHEMA_VERSION = 1
MAXIMUM_BYTES = 512_000
RVP_SPONSOR_ID = "rvp-supply-oem-beadlocks"

# Wheel IDs with bundled artwork on BOTH clients (iOS asset catalog, Android drawables). Any other
# wheel needs imageURL. Keep in sync with RVPWheelProduct.catalog and the README mapping table.
BUNDLED_WHEEL_IDS = {
    "oem-hellcat", "oem-hellcat-v2", "oem-hellcat-redeye", "5-spoke-hellcat", "5-spoke-hellcat-v2",
    "oem-demon", "hollow-5-spoke", "chrome-oem-hellcat", "oem-widebody",
}

LIMITS = {
    "brands": 30, "wheels": 24, "id": 64, "revision": 200, "name": 60, "tagline": 120,
    "description": 500, "ctaTitle": 60, "accessibilityText": 500, "priceText": 60,
    "subtitle": 120, "footnote": 160, "offerCode": 40, "offerText": 300, "maximumAmountOff": 10_000,
}

# Rejected by the apps in neutral `brand` copy.
NEUTRAL_BANNED = ["sponsor", "partner", "affiliate", "endorse"]
# Dashboard-only warnings (the native FeaturedGearTests guards). Not enforced by the apps.
DASHBOARD_WARN = [
    "official", "exclusive", "guarantee", "universal", "fits all", "all vehicles", "horsepower",
    "racing", "fastest", "strongest", "85blends", "authorized", "trusted", "preferred", "powered by",
]

ID_PATTERN = re.compile(r"^[a-z0-9-]{1,64}$")


class Invalid(Exception):
    pass


class Unsupported(Exception):
    pass


def secure_url(value) -> bool:
    if not isinstance(value, str):
        return False
    try:
        parts = urlsplit(value)
    except ValueError:
        return False
    return (
        parts.scheme.lower() == "https"
        and bool(parts.hostname)
        and parts.username is None
        and parts.password is None
        and not any(ch.isspace() for ch in value)
    )


def text(value, limit: int) -> bool:
    # Swift counts grapheme clusters; code points are a close, slightly stricter approximation.
    return isinstance(value, str) and value.strip() != "" and len(value) <= limit


def timestamp(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value > 0


def optional(obj: dict, key: str, check) -> bool:
    return key not in obj or obj[key] is None or check(obj[key])


def validate_shared(brand: dict) -> None:
    bid = brand["id"]
    if not (text(brand.get("name"), LIMITS["name"]) and text(brand.get("tagline"), LIMITS["tagline"])
            and text(brand.get("description"), LIMITS["description"])
            and text(brand.get("ctaTitle"), LIMITS["ctaTitle"])
            and optional(brand, "accessibilityDescription", lambda v: text(v, LIMITS["accessibilityText"]))):
        raise Invalid(f"{bid}: text missing or too long")
    more = brand.get("more")
    if more is not None:
        if not isinstance(more, dict) or not optional(more, "subtitle", lambda v: text(v, LIMITS["subtitle"])):
            raise Invalid(f"{bid}: more")
    if not secure_url(brand.get("destinationURL")):
        raise Invalid(f"{bid}: destinationURL must be https")
    if not optional(brand, "hidden", lambda v: isinstance(v, bool)):
        raise Invalid(f"{bid}: hidden must be a boolean")


def validate_neutral(brand: dict) -> None:
    validate_shared(brand)
    bid = brand["id"]
    if bid == RVP_SPONSOR_ID:
        raise Invalid("the RVP Supply id is reserved for rvp_wheels")
    for key in ("homepageURL", "configuratorURL", "footnote", "wheels"):
        if brand.get(key) is not None:
            raise Invalid(f"{bid}: {key} is only allowed on rvp_wheels")
    copy = " ".join(str(brand.get(k) or "") for k in ("name", "tagline", "description", "ctaTitle",
                                                      "accessibilityDescription"))
    copy += " " + str((brand.get("more") or {}).get("subtitle") or "")
    for word in NEUTRAL_BANNED:
        if word in copy.lower():
            raise Invalid(f"{bid}: neutral brand copy may not say '{word}'")
    if not optional(brand, "heroImageURL", secure_url):
        raise Invalid(f"{bid}: heroImageURL")
    logo = brand.get("logo")
    if logo is not None and not (isinstance(logo, dict) and secure_url(logo.get("url"))
                                 and optional(logo, "darkURL", secure_url)):
        raise Invalid(f"{bid}: logo")
    if not optional(brand, "priceText", lambda v: text(v, LIMITS["priceText"])):
        raise Invalid(f"{bid}: priceText")
    offer = brand.get("offer")
    if offer is not None:
        amount = offer.get("amountOff") if isinstance(offer, dict) else None
        if not (isinstance(amount, int) and not isinstance(amount, bool)
                and 1 <= amount <= LIMITS["maximumAmountOff"]):
            raise Invalid(f"{bid}: offer.amountOff must be a whole number 1-{LIMITS['maximumAmountOff']}")
        code = offer.get("code")
        if not (text(code, LIMITS["offerCode"]) and not any(c.isspace() for c in code)):
            raise Invalid(f"{bid}: offer.code")
        for key in ("eligibleProducts", "terms", "disclosure"):
            if not text(offer.get(key), LIMITS["offerText"]):
                raise Invalid(f"{bid}: offer.{key}")
        if not (optional(offer, "startsAt", timestamp) and optional(offer, "expiresAt", timestamp)):
            raise Invalid(f"{bid}: offer timestamps must be positive UTC Unix seconds")
        if offer.get("startsAt") is not None and offer.get("expiresAt") is not None \
                and offer["startsAt"] >= offer["expiresAt"]:
            raise Invalid(f"{bid}: offer.startsAt must be before expiresAt")


def validate_sponsor(brand: dict) -> None:
    validate_shared(brand)
    if brand["id"] != RVP_SPONSOR_ID:
        raise Invalid("rvp_wheels is reserved for RVP Supply")
    for key in ("offer", "priceText", "heroImageURL", "logo"):
        if brand.get(key) is not None:
            raise Invalid(f"rvp_wheels may not carry {key}")
    if not (secure_url(brand.get("homepageURL")) and secure_url(brand.get("configuratorURL"))):
        raise Invalid("rvp_wheels needs https homepageURL and configuratorURL")
    if not optional(brand, "footnote", lambda v: text(v, LIMITS["footnote"])):
        raise Invalid("rvp_wheels footnote")
    wheels = brand.get("wheels") or []
    if not isinstance(wheels, list) or len(wheels) > LIMITS["wheels"]:
        raise Invalid("too many wheels")
    ids = [w.get("id") if isinstance(w, dict) else None for w in wheels]
    if not all(isinstance(i, str) and ID_PATTERN.match(i) for i in ids) or len(set(ids)) != len(ids):
        raise Invalid("wheel ids must be unique lowercase [a-z0-9-]")
    for wheel in wheels:
        wid = wheel["id"]
        if not (text(wheel.get("displayName"), LIMITS["name"])
                and text(wheel.get("accessibilityName"), LIMITS["accessibilityText"])
                and secure_url(wheel.get("productURL")) and optional(wheel, "imageURL", secure_url)
                and optional(wheel, "hidden", lambda v: isinstance(v, bool))):
            raise Invalid(f"wheel {wid}")
        if wheel.get("imageURL") is None and wid not in BUNDLED_WHEEL_IDS:
            raise Invalid(f"wheel {wid}: needs imageURL (no bundled artwork for this id)")


def validate(document: dict) -> list[str]:
    """Raises Invalid/Unsupported; returns dashboard warnings."""
    if not isinstance(document, dict):
        raise Invalid("not a catalog document")
    version = document.get("schemaVersion")
    if not isinstance(version, int) or isinstance(version, bool):
        raise Invalid("schemaVersion")
    if version != SUPPORTED_SCHEMA_VERSION:
        raise Unsupported(f"schemaVersion {version} is not readable by v1 clients")
    if not text(document.get("revision"), LIMITS["revision"]):
        raise Invalid("revision")
    if not timestamp(document.get("publishedAt")):
        raise Invalid("publishedAt")
    brands = document.get("brands")
    if not isinstance(brands, list) or len(brands) > LIMITS["brands"]:
        raise Invalid("brands")
    ids = []
    for entry in brands:
        if not isinstance(entry, dict) or not isinstance(entry.get("kind"), str):
            raise Invalid("every brand needs a kind")
        bid = entry.get("id")
        if not (isinstance(bid, str) and ID_PATTERN.match(bid)):
            raise Invalid(f"brand id {bid!r}")
        ids.append(bid)
    if len(set(ids)) != len(ids):
        raise Invalid("duplicate brand id")

    warnings = []
    sponsors = 0
    for entry in brands:
        kind = entry["kind"]
        if kind == "brand":
            validate_neutral(entry)
            blob = " ".join(str(entry.get(k) or "") for k in ("name", "tagline", "description", "ctaTitle")).lower()
            warnings += [f"{entry['id']}: review wording '{w}'" for w in DASHBOARD_WARN if w in blob]
        elif kind == "rvp_wheels":
            sponsors += 1
            validate_sponsor(entry)
        else:
            warnings.append(f"{entry['id']}: kind '{kind}' is unknown to v1 clients and will be skipped")
    if sponsors > 1:
        raise Invalid("more than one rvp_wheels entry")
    return warnings


def validate_bytes(raw: bytes) -> tuple[dict, list[str]]:
    if len(raw) > MAXIMUM_BYTES:
        raise Invalid(f"document is {len(raw)} bytes; limit {MAXIMUM_BYTES}")
    try:
        document = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise Invalid(f"not JSON: {error}")
    return document, validate(document)


def check_successor(previous: dict, candidate: dict) -> None:
    """Rules for publishing `candidate` over the live `previous` document."""
    if candidate["publishedAt"] < previous["publishedAt"]:
        raise Invalid("publishedAt is older than the live publication; devices would ignore it")
    if candidate["revision"] == previous["revision"]:
        raise Invalid("revision must change on every publication, including a rollback")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("catalog")
    parser.add_argument("--previous", help="the currently published document")
    args = parser.parse_args(argv)
    try:
        with open(args.catalog, "rb") as handle:
            document, warnings = validate_bytes(handle.read())
        if args.previous:
            with open(args.previous, "rb") as handle:
                previous, _ = validate_bytes(handle.read())
            check_successor(previous, document)
    except (Invalid, Unsupported) as error:
        print(f"REJECTED: {error}")
        return 1
    for warning in warnings:
        print(f"warning: {warning}")
    brands = [b for b in document["brands"] if not b.get("hidden")]
    print(f"OK: revision {document['revision']}, {len(brands)} visible brand(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

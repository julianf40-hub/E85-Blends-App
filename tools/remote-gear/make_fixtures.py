#!/usr/bin/env python3
"""Generate a numbered sequence of STAGING test catalogs for Internal simulator/device testing.

    python3 tools/remote-gear/make_fixtures.py /tmp/gear-fixtures

Each file is a complete v1 document. Apply them IN ORDER with the Internal developer card
(Preferences → Recommended Gear Catalog → Staging → "Load Fixture from Clipboard"), e.g.

    xcrun simctl pbcopy booted < /tmp/gear-fixtures/02-add-example-brand.json

publishedAt increases by one second per file, starting at generation time, so the sequence obeys
the ordering rules. Offer times are relative to generation time: generate just before testing.
Uses a fictional brand ("Example Fuel Tools", example.com URLs); no real partner copy is changed.
Nothing is uploaded anywhere.
"""

from __future__ import annotations

import copy
import json
import pathlib
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
SEED = ROOT / "docs/remote-gear/catalog-v1.json"

EXAMPLE = {
    "id": "example-fuel-tools",
    "kind": "brand",
    "name": "Example Fuel Tools",
    "tagline": "Test brand for staging only",
    "description": "A fictional brand used to test adding, editing, hiding and removing cards.",
    "ctaTitle": "View Example Products",
    "destinationURL": "https://example.com/fuel-tools",
    "priceText": "From $49",
    "more": {"subtitle": "Staging test card"},
    # Deliberately unreachable (.invalid never resolves): exercises the image and logo fallbacks.
    "logo": {"url": "https://example.invalid/gear/example-logo-v1.png"},
    "heroImageURL": "https://example.invalid/gear/example-hero-v1.png",
}


def scenarios(now: int) -> list[tuple[str, str, dict]]:
    seed = json.loads(SEED.read_text())
    eflex, rvp = seed["brands"]
    example = copy.deepcopy(EXAMPLE)

    edited = copy.deepcopy(example)
    edited["tagline"] = "Edited tagline from staging"
    edited["priceText"] = "From $39"
    edited["offer"] = {
        "amountOff": 10, "eligibleProducts": "example test kits", "code": "STAGING10",
        "terms": "Test offer for staging only.", "disclosure": "Not a real promotion.",
        "startsAt": now + 120, "expiresAt": now + 300,
    }
    hidden = dict(copy.deepcopy(edited), hidden=True)
    eight_wheels = copy.deepcopy(rvp)
    eight_wheels["wheels"][-1]["hidden"] = True

    return [
        ("01-seed-parity", "Same as the bundled catalog. Nothing visible should change.", [eflex, rvp]),
        ("02-add-example-brand", "Adds a fictional first card with a price and broken remote images "
         "(typographic name, neutral placeholder, no eFlexFuel styling) and a More card.", [example, eflex, rvp]),
        ("03-reorder", "RVP first, then eFlexFuel, then the example brand. The selected card is kept.", [rvp, eflex, example]),
        ("04-edit-with-offer-window", "Edits copy and price; neutral-styled offer appears 2 min after "
         "generation and disappears at 5 min (test offline too).", [rvp, eflex, edited]),
        ("05-hide-example", "Example brand hidden: gone from Recommended Gear AND More.", [rvp, eflex, hidden]),
        ("06-eight-wheels", "One wheel hidden: the ring becomes the labeled grid.", [eight_wheels, eflex]),
        ("07-remove-eflexfuel", "eFlexFuel removed: open it from More first, then apply; the "
         "carousel must move to the remaining card and the More card disappears.", [rvp]),
        ("08-empty", "Valid empty catalog: empty state on Recommended Gear, no partner cards on More.", []),
        ("09-rollback-to-parity", "Rollback = new publication of the seed content.", [eflex, rvp]),
    ]


def build(now: int | None = None) -> list[tuple[str, str, dict]]:
    now = int(time.time()) if now is None else now
    documents = []
    for index, (name, note, brands) in enumerate(scenarios(now)):
        documents.append((name, note, {
            "schemaVersion": 1,
            "revision": f"staging-fixture-{now}-{name}",
            "publishedAt": now + index,
            "brands": brands,
        }))
    return documents


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__)
        return 2
    out = pathlib.Path(argv[0])
    out.mkdir(parents=True, exist_ok=True)
    for name, note, document in build():
        (out / f"{name}.json").write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n")
        print(f"{name}.json  {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

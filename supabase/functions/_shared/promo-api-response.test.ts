// 85Blends 2.4.0 — Tests for promo-api-response.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  buildRedemptionUrl,
  buildCampaignPresentation,
  buildValidateResponse,
  buildClaimSuccessResponse,
  buildStatusResponse,
  deriveClaimStatus,
} from "./promo-api-response.ts";

const SAMPLE_CAMPAIGN = {
  publicCode: "85BLENDS",
  displayTitle: "1 month of Pro, on us",
  displaySubtitle: "For new subscribers only",
  displayBadge: "Limited",
  displayTerms: "First 100 claims. One per person.",
  ctaLabel: "Claim now",
};

test("buildRedemptionUrl: matches the exact required shape and parameter order", () => {
  const url = buildRedemptionUrl("ABCD1234EFGH");
  assert.equal(url, "https://apps.apple.com/redeem?ctx=offercodes&id=6762037468&code=ABCD1234EFGH");
});

test("buildRedemptionUrl: percent-encodes an Apple code containing characters that need it", () => {
  const url = buildRedemptionUrl("AB CD/12+34");
  assert.ok(url.startsWith("https://apps.apple.com/redeem?ctx=offercodes&id=6762037468&code="));
  // Decoding the query param must round-trip to the exact original code.
  const params = new URL(url).searchParams;
  assert.equal(params.get("code"), "AB CD/12+34");
});

test("buildRedemptionUrl: never appears verbatim outside the URL — the code is not otherwise interpolated by this module", () => {
  const url = buildRedemptionUrl("SECRETCODE1");
  const occurrences = url.split("SECRETCODE1").length - 1;
  assert.equal(occurrences, 1);
});

test("buildCampaignPresentation: maps every field, preserving nulls", () => {
  const presentation = buildCampaignPresentation(SAMPLE_CAMPAIGN);
  assert.deepEqual(presentation, {
    public_code: "85BLENDS",
    display_title: "1 month of Pro, on us",
    display_subtitle: "For new subscribers only",
    display_badge: "Limited",
    display_terms: "First 100 claims. One per person.",
    cta_label: "Claim now",
  });
});

test("buildCampaignPresentation: optional fields pass through null cleanly", () => {
  const presentation = buildCampaignPresentation({
    ...SAMPLE_CAMPAIGN,
    displaySubtitle: null,
    displayBadge: null,
    displayTerms: null,
    ctaLabel: null,
  });
  assert.equal(presentation.display_subtitle, null);
  assert.equal(presentation.display_badge, null);
  assert.equal(presentation.display_terms, null);
  assert.equal(presentation.cta_label, null);
});

test("buildValidateResponse: assembles the exact documented shape", () => {
  const response = buildValidateResponse({
    ...SAMPLE_CAMPAIGN,
    selectedProductId: "com.85blends.subscription.monthly",
    claimLimitReached: false,
    alreadyClaimed: false,
    claimedProductId: null,
  });
  assert.deepEqual(response, {
    valid: true,
    campaign: {
      public_code: "85BLENDS",
      display_title: "1 month of Pro, on us",
      display_subtitle: "For new subscribers only",
      display_badge: "Limited",
      display_terms: "First 100 claims. One per person.",
      cta_label: "Claim now",
      selected_product_id: "com.85blends.subscription.monthly",
      claim_limit_reached: false,
      already_claimed: false,
      claimed_product_id: null,
    },
  });
});

test("buildValidateResponse: reflects claim_limit_reached and already_claimed independently", () => {
  const response = buildValidateResponse({
    ...SAMPLE_CAMPAIGN,
    selectedProductId: "com.85blends.subscription.annual",
    claimLimitReached: true,
    alreadyClaimed: true,
    claimedProductId: "com.85blends.subscription.monthly",
  });
  assert.equal(response.campaign.claim_limit_reached, true);
  assert.equal(response.campaign.already_claimed, true);
  assert.equal(response.campaign.claimed_product_id, "com.85blends.subscription.monthly");
});

test("buildValidateResponse: never issues a redemption URL or an Apple code — the response has no such field", () => {
  const response = buildValidateResponse({
    ...SAMPLE_CAMPAIGN,
    selectedProductId: "com.85blends.subscription.monthly",
    claimLimitReached: false,
    alreadyClaimed: false,
    claimedProductId: null,
  });
  assert.equal("redemption_url" in response, false);
  assert.equal("redemption_url" in response.campaign, false);
  assert.equal(JSON.stringify(response).includes("apps.apple.com"), false);
});

test("buildClaimSuccessResponse: assembles the exact documented shape, embedding the code only inside redemption_url", () => {
  const response = buildClaimSuccessResponse({
    claimId: "11111111-1111-1111-1111-111111111111",
    campaign: SAMPLE_CAMPAIGN,
    selectedProductId: "com.85blends.subscription.monthly",
    appleCode: "APPLECODE123",
  });
  assert.deepEqual(response, {
    claim_id: "11111111-1111-1111-1111-111111111111",
    campaign: {
      public_code: "85BLENDS",
      display_title: "1 month of Pro, on us",
      display_subtitle: "For new subscribers only",
      display_badge: "Limited",
      display_terms: "First 100 claims. One per person.",
      cta_label: "Claim now",
    },
    selected_product_id: "com.85blends.subscription.monthly",
    redemption_url: "https://apps.apple.com/redeem?ctx=offercodes&id=6762037468&code=APPLECODE123",
  });
  // The raw code must appear exactly once in the whole serialized response — inside the URL only.
  const serialized = JSON.stringify(response);
  const occurrences = serialized.split("APPLECODE123").length - 1;
  assert.equal(occurrences, 1);
});

test("buildStatusResponse: not_claimed never includes a product or redemption URL", () => {
  const response = buildStatusResponse({
    status: "not_claimed",
    campaign: SAMPLE_CAMPAIGN,
    selectedProductId: null,
    appleCode: null,
  });
  assert.deepEqual(response, {
    status: "not_claimed",
    campaign: {
      public_code: "85BLENDS",
      display_title: "1 month of Pro, on us",
      display_subtitle: "For new subscribers only",
      display_badge: "Limited",
      display_terms: "First 100 claims. One per person.",
      cta_label: "Claim now",
    },
    selected_product_id: null,
    redemption_url: null,
  });
});

test("buildStatusResponse: claimed includes the product and a redemption URL identical to buildRedemptionUrl's own output", () => {
  const response = buildStatusResponse({
    status: "claimed",
    campaign: SAMPLE_CAMPAIGN,
    selectedProductId: "com.85blends.subscription.threemonth",
    appleCode: "APPLECODE456",
  });
  assert.equal(response.status, "claimed");
  assert.equal(response.selected_product_id, "com.85blends.subscription.threemonth");
  assert.equal(response.redemption_url, buildRedemptionUrl("APPLECODE456"));
});

test("buildStatusResponse: redeemed never carries a redemption URL — it has already served its purpose (Phase ... hardening)", () => {
  const response = buildStatusResponse({
    status: "redeemed",
    campaign: SAMPLE_CAMPAIGN,
    selectedProductId: "com.85blends.subscription.annual",
    appleCode: "STABLECODE",
  });
  assert.equal(response.status, "redeemed");
  assert.equal(response.redemption_url, null);
  assert.equal(JSON.stringify(response).includes("STABLECODE"), false);
});

test("buildStatusResponse: expired never carries a redemption URL — Apple will no longer accept the code", () => {
  const response = buildStatusResponse({
    status: "expired",
    campaign: SAMPLE_CAMPAIGN,
    selectedProductId: "com.85blends.subscription.monthly",
    appleCode: "EXPIREDCODE1",
  });
  assert.equal(response.status, "expired");
  assert.equal(response.redemption_url, null);
  assert.equal(JSON.stringify(response).includes("EXPIREDCODE1"), false);
});

test("buildStatusResponse: void never carries a redemption URL", () => {
  const response = buildStatusResponse({
    status: "void",
    campaign: SAMPLE_CAMPAIGN,
    selectedProductId: "com.85blends.subscription.threemonth",
    appleCode: "VOIDEDCODE1",
  });
  assert.equal(response.status, "void");
  assert.equal(response.redemption_url, null);
  assert.equal(JSON.stringify(response).includes("VOIDEDCODE1"), false);
});

test("buildStatusResponse: a non-null appleCode alongside a non-'claimed' status is defensively ignored — the gate is on status, not on appleCode's presence", () => {
  for (const status of ["not_claimed", "expired", "redeemed", "void"] as const) {
    const response = buildStatusResponse({
      status,
      campaign: SAMPLE_CAMPAIGN,
      selectedProductId: null,
      appleCode: "SHOULD-NEVER-LEAK",
    });
    assert.equal(response.redemption_url, null, `status ${status} must never emit a redemption_url`);
  }
});

// MARK: — deriveClaimStatus

test("deriveClaimStatus: a live, unexpired, unredeemed claim is 'claimed'", () => {
  assert.equal(
    deriveClaimStatus({ claimStatus: "claimed", offerCodeStatus: "issued", offerCodeExpired: false }),
    "claimed",
  );
});

test("deriveClaimStatus: claim.status 'void' wins regardless of the code's own status", () => {
  assert.equal(deriveClaimStatus({ claimStatus: "void", offerCodeStatus: "issued", offerCodeExpired: false }), "void");
  assert.equal(deriveClaimStatus({ claimStatus: "void", offerCodeStatus: "available", offerCodeExpired: false }), "void");
});

test("deriveClaimStatus: the code's own status 'void' wins even if the claim row itself is still 'claimed'", () => {
  assert.equal(deriveClaimStatus({ claimStatus: "claimed", offerCodeStatus: "void", offerCodeExpired: false }), "void");
});

test("deriveClaimStatus: claim.status 'redeemed' wins over a non-expired code", () => {
  assert.equal(
    deriveClaimStatus({ claimStatus: "redeemed", offerCodeStatus: "issued", offerCodeExpired: false }),
    "redeemed",
  );
});

test("deriveClaimStatus: the code's own status 'redeemed' wins even if the claim row itself is still 'claimed'", () => {
  assert.equal(
    deriveClaimStatus({ claimStatus: "claimed", offerCodeStatus: "redeemed", offerCodeExpired: false }),
    "redeemed",
  );
});

test("deriveClaimStatus: an expired, still-issued code on an otherwise-claimed claim is 'expired'", () => {
  assert.equal(
    deriveClaimStatus({ claimStatus: "claimed", offerCodeStatus: "issued", offerCodeExpired: true }),
    "expired",
  );
});

test("deriveClaimStatus: void beats expired — a voided-and-also-expired code is reported as void", () => {
  assert.equal(
    deriveClaimStatus({ claimStatus: "void", offerCodeStatus: "void", offerCodeExpired: true }),
    "void",
  );
});

test("deriveClaimStatus: redeemed beats expired — a redeemed code that has since passed its expiry is still 'redeemed'", () => {
  assert.equal(
    deriveClaimStatus({ claimStatus: "redeemed", offerCodeStatus: "redeemed", offerCodeExpired: true }),
    "redeemed",
  );
});

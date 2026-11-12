# Recommended Gear publishing dashboard — proposal

Status: **design only. Nothing here is built, migrated or deployed.** The mobile contract in
`README.md` is the fixed input to this design. The dashboard must produce documents that pass
`tools/remote-gear/validate_catalog.py`.

## Requirements

| Need | Approach |
|---|---|
| Private editor | Web app behind Supabase Auth. Only allowlisted administrators see anything. |
| Edit text, links, prices, offers, order, hide/remove | Form generated from `catalog-v1.schema.json`, with drag-to-reorder, a per-item hidden toggle, and character counters at the client limits. |
| Image uploads | Server-issued signed upload URLs to content-addressed (immutable) paths, with type and size checks. |
| Draft preview | Web preview of both screens (light/dark, narrow/wide, large text) plus an optional **staging object** a TestFlight build can be pointed at. |
| Validation | Same rules as the apps, run in the browser (fast feedback) **and again on the server** (authoritative). |
| Publish | One server action: validate, stamp `publishedAt`, record history, upload the public object. |
| Rollback | Re-publish any history entry as a **new** publication. |
| Partner approval | A per-brand `approval` state in the draft (not in the public document). Publishing is blocked while an included, visible brand is "pending" (eFlexFuel is pending today). |
| Audit | Every save, publish and rollback recorded with user, time, revision and diff summary. |

## Authentication

- Supabase Auth on the existing project. Email magic link or SSO, **plus mandatory TOTP MFA**.
  The server requires `aal2` in the JWT for every write.
- Public sign-ups disabled for the dashboard. Administrators are invited by an owner.
- Short sessions (for example a 1 h access token and refresh rotation). No credentials are ever
  stored in either mobile app.

## Administrator authorization

- Table `gear_admins (user_id uuid primary key references auth.users, role text check (role in
  ('editor','publisher')), added_by uuid, added_at timestamptz)`. RLS: only service role writes,
  and an admin can read their own row.
- `editor` can create and edit drafts and upload images. `publisher` can also publish and roll
  back. Optionally require a second publisher to approve a publish.
- Tables `gear_catalog_drafts` and `gear_catalog_publications` (jsonb document, revision,
  published_at, published_by, source_publication_id for rollbacks, validator version). RLS:
  SELECT/INSERT/UPDATE only for users present in `gear_admins` with the right role, **and**
  `auth.jwt()->>'aal' = 'aal2'`. No anon access. Publications are append-only (no UPDATE/DELETE
  policy).
- Storage bucket `recommended-gear`: public **read**, and **no** INSERT/UPDATE/DELETE policies
  for `anon` or `authenticated`. All writes are made by the Edge Functions below using the
  service role, which lives only in Edge Function secrets, never in a browser or an app.

## Publication flow

```text
editor ── edit draft (RLS-protected table) ──► browser validator (instant)
       ── upload image ─► fn gear-upload-url (auth + role + aal2)
                           └─ signed upload URL for images/<brand>/<sha256>.<ext>
                              (type png/jpeg/heic, ≤ 5 MB, ≤ 8,192 px per side; reject overwrite)
publisher ── Publish ─► fn gear-publish (auth + publisher + aal2)
   1. load draft; refuse if base revision ≠ current live revision (optimistic lock)
   2. refuse if any visible brand has approval = pending
   3. strip dashboard-only fields; set revision = new UUID, publishedAt = next timestamp (below)
   4. run the validator (TypeScript port of validate_catalog.py, same test cases)
      + successor check against the live document
   5. HEAD every referenced image (must exist, 200, image/*)
   6. insert into gear_catalog_publications (append-only)
   7. upload catalog-v1.json  (Content-Type application/json, Cache-Control max-age=60)
   8. read the public URL back and compare bytes; record CDN check result
publisher ── Rollback(publication X) ─► same function, with X's document as the draft
```

### Strictly increasing `publishedAt`

Devices accept a changed publication only if its `publishedAt` is **strictly** greater than the
last one they accepted, and its revision is new (README, "Publication ordering"). The publisher
guarantees this even for rapid successive publishes and concurrent publishers:

- A single row `gear_publication_head (id = 1, revision, published_at bigint, digest)` is locked
  with `SELECT … FOR UPDATE` inside the publish transaction, so publishes are serialized.
- `published_at = greatest(floor(extract(epoch from clock_timestamp())), head.published_at + 1)`,
  in whole seconds. Two publishes in the same second get t and t + 1. A server clock that moved
  backwards still yields head + 1. Integers are exact in JSON and in a Double on both platforms.
- `revision` is a fresh UUID with a UNIQUE constraint in `gear_catalog_publications`, so a
  revision can never be reused.
- The transaction inserts the history row and updates the head **before** the Storage upload. The
  uploaded bytes are the exact bytes recorded, so a retry after a failed upload re-sends identical
  bytes, which devices accept as "unchanged". If the upload ultimately fails, the next publish still
  moves forward from the recorded head.
- Rollback calls the same path with the old document as input, so it gets a new revision and the
  next timestamp. It is never a re-upload of old bytes.
- The validator's successor check (TypeScript port of `check_successor`) runs against the head
  inside the transaction, as a final guard.

Preview: `gear-publish` with `target: "staging"` writes `staging/catalog-v1.json` instead,
skipping the approval gate. TestFlight, Xcode and Debug installs read that path when the catalog
card's source is set to Staging (README §4a). App Store installs can never select it: the store
rejects staging unless StoreKit verifies a sandbox environment.

## Risks and decisions for Julian

- Hosting for the dashboard (for example a static site on an existing domain behind Supabase Auth).
- Who the first publishers are, and whether two-person publish is required.
- Supabase plan: confirm Smart CDN behaviour and the Storage egress budget for images.
- Retention of publication history (indefinite is recommended; documents are small).

## Next concrete step

Write, **for review only**, a migration that adds `gear_admins`, `gear_catalog_drafts`,
`gear_catalog_publications` with the RLS policies above, plus a `gear-publish` Edge Function
skeleton with a TypeScript port of the validator and its tests. Run it against a Supabase
**branch or staging project**, never production. That step needs Julian's go-ahead, because it is
a schema/migration change and a new backend surface.

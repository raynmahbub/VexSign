# Data architecture: the library store and its invariants

VexSign keeps its library in one Core Data store. This note records what the store actually
guarantees, what it does not, and the read-only audit that reports the difference. It is
written against the source, not against intentions: every statement below was checked in
`App/iOS/VexSign/Backend/Storage/`, `App/iOS/VexSign/Backend/Observable/` and `App/iOS/VexSign/Security/`.

## What the store is

| Property | Value |
|---|---|
| Framework | Core Data (`NSPersistentContainer`), one store per app install |
| Model | `VexSign.xcdatamodeld` → `VexSign.xcdatamodel`, one version, `codeGenerationType="class"` |
| Entities | `AltSource`, `CertificatePair`, `Imported`, `Signed` |
| Attributes | 33 across the four entities |
| Relationships | `CertificatePair.signedApps` ⟷ `Signed.certificate` |
| Unique constraints | **none** |
| Fetch indexes | **none** |
| Store file | `VexSign.sqlite` in Application Support |

`Feather.sqlite` is migrated to `VexSign.sqlite` on first launch. If the move fails, the old
file is opened **in place** rather than replaced: losing the library to a successful-looking
migration would be worse than keeping the old filename.

Writes go through one lazily created background context
(`NSMergeByPropertyObjectTrump`, `automaticallyMergesChangesFromParent`). Reads use
`viewContext`. `StorageConcurrency.requireMainQueue` reports off-main reads — it logs and,
in debug builds, `NSLog`s, but it does not trap. It is a diagnostic, not a gate.

Signing secrets are not in the database. `CertificatePair.password` exists as a legacy
column; the live value is in the Keychain under `certificate.password.<uuid>`
(`SecureSecretStore`, migrated by `CertificatePasswordMigration`), and the column is
nil-ed out once the secret is stored.

## Invariants the store does not enforce

A row and its artifact directory are linked by nothing but a `uuid` string. Because the
model declares no unique constraint and no index, all of the following are *possible* states
that Core Data will accept:

1. two rows with the same `uuid` — an ambiguous directory and an ambiguous lookup;
2. a row with no `uuid` — no directory, no way to resolve the row;
3. a row whose artifact directory is gone — an app that cannot be opened, signed or installed;
4. a row with no bundle identifier — cannot be matched, updated or signed;
5. a signed row naming no identity;
6. a signed row whose `certificate` relationship points at a deleted `CertificatePair`.

No current caller is known to create (1) or (2) — uuids come from `AppFileHandler` and from
signing — but nothing prevents it, and (3) is reachable by any filesystem-level loss,
including a restore that brings the database back without its artifacts.

## `LibraryIntegrityAudit`

`App/iOS/VexSign/Backend/Storage/LibraryIntegrityAudit.swift` checks those six states over a
snapshot of rows. It is pure: it takes `[Row]` and a set of known certificate uuids, and
returns a `Report`. It does not fetch, mutate, delete or repair anything — repairing a
library is a separate, user-visible operation and is deliberately not part of this type.

Findings carry a `Code` and the index of the affected row, sorted by row and then code so
two audits of the same snapshot compare equal. Severity separates "the row is unusable"
(`duplicateUUID`, `missingUUID`, `artifactMissing`, `identifierMissing`) from "the row works
but its provenance is gone" (`signedWithoutCertificate`, `orphanedCertificate`).

The audit is attached to the diagnostic bundle as `integrity.json`. It exports **counts and a
one-sentence summary only** — no app names, no bundle identifiers, no uuids — because a
support bundle should not enumerate what a user has installed.

`Storage+Shared.getAllApps()` is a main-queue fetch, so the export builder is `@MainActor`,
matching the existing certificate summary builder next to it.

## Why the schema was not changed

Adding `uuid` uniqueness and fetch indexes would make (1) and (2) impossible and speed up
the identifier/uuid lookups every screen performs. It would also be a production schema
version change on a live store with no migration rehearsal possible here: no device, no
simulator, no toolchain in this environment. The current model has one version and no
`.xccurrentversion` migration mapping. A unique constraint on an existing store with
duplicate rows fails at load time, turning a cosmetic defect into an unopenable library.

The order that is safe is therefore: observe first (this audit), then — once real libraries
have been checked and a mapping model with tests exists — consider a lightweight migration.
That is a recommendation, not a change made here.

## Known limitations

- The audit reads one snapshot; it does not re-check after a repair because there is no repair.
- `viewContext` reads are main-queue by convention, not by enforcement.
- Nothing verifies artifact *integrity* (that an `.ipa` still unpacks and matches its
  recorded identifier); only presence is checked.
- Caches (repository catalogs, icons, device inventories) are derived state and must not be
  consulted for signing decisions; nothing in this audit reads them.
- No stress or benchmark numbers are claimed here: none were measured.

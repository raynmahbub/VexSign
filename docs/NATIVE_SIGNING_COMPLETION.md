# Native end-to-end completion ledger

Status: **unfinished; not integrated into normal app**. Checked items below mean
source implementation exists, not that it compiled or passed native/device tests.
The user requested coding first; do not dispatch Actions until that phase is ready.

## Dependency order

1. [x] Account/session, owned identity, quota-approved certificate/registration/profile
   creation/recovery source in isolated native module.
2. [x] Concrete profile CMS verifier source; default selection remains disabled.
3. [x] Supported ZIP32 namespace/index and bounded stored/deflate/all-entry checksum
   and content scan source; public read-only inspection receipt.
4. [x] Development leaf/WWDR/root purpose/chain verifier source with **required
   positive cached revocation**, never unknown=valid or network inferred from login.
5. [x] Source implementation of explicit scoped online certificate-status consent,
   reviewed WWDR G3 issuer supply and public backend status APIs. Positive status
   remains required; unsupported issuer generations block. Native validation pending.
6. [x] Read-only protected pre-sign artifact assembly: whole archive/entry hashes,
   fresh owned projection, reauthenticated CMS, concrete certificate evaluation,
   exact owner/context/target binding, deadline and retained namespace lifetime.
7. [ ] Explicit signing approval plus protected live vault/key delegation to a
   strict concrete engine. No UI/key/PKCS12 export; no first-profile fallback.
8. [ ] Full supported Mach-O semantics, code-directory/CMS/output verification,
   resource mutation allowlist, private workspace/extraction and packaging.
9. [ ] Pairing/device-bound installation consuming only verified signed artifacts,
   retained cancellation workers and device-side confirmation/reconciliation.
10. [ ] Durable quota-safe renewal/refresh transaction and explicit recovery from
    uncertain signing/install states; no timer-based quota writes or silent resets.
11. [ ] Normal-app package/link assembly and event-driven five-tab UI wiring to
    actual native operations. Dependency/license/host constraints remain real.
12. [ ] Native compiler/positive-negative trust/revocation/ABI/archive/worker tests,
    Actions and device acceptance after coding phase; installer compatibility must
    be verified individually. Existing certificate-import crash is still unresolved.

## Concrete engine review finding

Immutable SideSign `AppBundleSigner` uses `profiles.first` when exact matching
fails; its keychain-group rewriting is not the native narrow entitlement policy.
Its `KeyStore` exposes private-key bytes and exports PKCS12; CodeSignKit's CMS
signer embeds a hardcoded issuer. Additional source review found dual XML/DER
entitlement output and noncanonical DER BOOLEAN true encoding (0x01). These APIs must NOT simply be wired to a green
UI readiness flag. Review hashes/paths are recorded in
`NativeSigning/development-certificate-review.json`; no SDK signing occurred.

## Test status

All latest native fixtures are written/unrun. Static grammar/Python syntax/diff
checks are not native compilation, cryptographic proof or end-to-end completion.
Production CMS/UI/capability gates remain closed; existing imported-certificate
sign/install/automation paths do not prove native free-account integration.

### Step 8 subcomponents implemented (source only, not whole-stage completion)

- [x] Independent narrow CodeDirectory page/special-slot/header/identity consistency.
- [x] Separate detached code-CMS digest/exact-signer/signature consistency; profile
  CMS continues to require attached content. Neither receipt is artifact authority.
- [x] Bounded deterministic stored ZIP32 transport with independent namespace and
  full record CRC/decode readback. No extraction or installer-facing artifact.
- [x] Hash-locked canonical DER boolean preparation correction, original preserved
  and before/after provenance recorded. Preparation/native engine not run.
- [x] Exact approved XML source plus independent canonical DER four-claim
  equivalence, including strict boolean/identity/group checks.
- [x] Archive-bound resource mutation allowlist and deterministic all-file seals,
  including unchanged Info.plist and exact expected profile; no omit/optional rules.
- [x] Five-slot superblob consistency composition (claims + directory + detached
  CMS), duplicate/alternate/overlap/gap/hidden-data rejection.
- [ ] Full Mach-O/entrypoint/dependency semantics, executable instruction/load-command
  mutation policy, designated-requirement policy, private workspace and opaque
  verified-artifact release. Consistency receipts are NOT installation authority.

Upstream unsigned-execution flags remain incompatible with the strict output
subset; they are rejected, not silently allowed. Eight native fixtures plus two
preparation regressions are written/unrun. 81 first-party inputs + four SDK
additions + one upstream correction; no readiness/production gate promotion.

### Narrow image mutation dialect (source only; full Mach-O gate still pending)

- [x] Bounded thin ARM64 segment/VM/section mappings, LC_MAIN instruction-range
  checks, terminal existing signature allocation, no W+X/DRM/alternate thread entry.
- [x] Exact original/output comparison excluding ONLY linkedit sizes and signature
  offset/size; no code/data/other-command moves/rewrites or command insertion.
- [x] Image-bound composition into claims/directory/CMS signature verification.
- [ ] Semantic authorization of preserved dyld/dependency/linkedit reference commands
  and designated requirements; real native fixtures/platform acceptance.

Five synthetic fixtures and one prep regression written/unrun. 88 mapped inputs;
no protected signing, verified artifact release, install, renewal or UI readiness
promotion. Partial structural/mutation evidence is not full Mach-O authority.

### Exact designated requirement dialect (source only)

- [x] Immutable Apple requirement opcode/alignment/interpreter/type source review.
- [x] One canonical designated expression: exact identifier AND leaf-certificate
  legacy SHA1 digest; no alternate/unknown/OR/skip clauses or unexamined bytes.
- [x] Enforced in composed main signature consistency before directory/CMS checks.
- [ ] Native platform evaluation and renewal/update continuity of leaf-pinned DRs.

Legacy SHA1 is requirement format only; exact DER/RSA-SHA256 CMS and fresh Apple
trust/profile/ownership checks remain separate mandatory boundaries. Full loader/
dependency/linkedit-reference policy, protected execution/workspace/artifact release,
install/renewal/UI remain unfinished. Five fixtures/one prep regression unrun;
91 inputs. No capability/default gate promotion or native execution.

### System-only loader envelope (source-only restricted dialect)

- [x] Fail unknown command forms closed; canonical system-only dylib/framework
  names, exact dyld and iPhoneOS metadata, singleton/dependency bounds.
- [x] Linkedit references cannot point into code/signature/outside file; limited
  symtab/dysymtab, string/section/library-ordinal bounds, no relocations/dynamic lookup.
- [x] Applied to original AND output before image-bound mutation/signature checks.
- [ ] Bind/rebase/export/chained-fixup bytecode and complete dyld semantic validation.

@rpath/embedded/private frameworks and other dependency dialects intentionally
reject, not fall back. Names do not prove installed dependency availability. Five
fixtures/one prep regression written/unrun; 93 mapped inputs, no native execution
or protected signing/artifact/install/refresh/UI readiness promotion.

### Legacy dyld bytecode subset (source implementation; native validation pending)

- [x] Bounded canonical ULEB/stateful pointer rebase + regular/lazy bind decoding,
  actual writable file-backed target/value checks, ordinal/symbol/type checks.
- [x] Bounded repeat/skip arithmetic, duplicate-target policy, explicit termination,
  cancellation/target budgets and supported rebase-then-lazy helper overlap.
- [x] Loader invokes decoder on actual streams; weak binding/nonempty exports and
  export-trie/chained commands reject rather than remain range-only accepted.
- [ ] Export/fixup/remaining linkedit payload semantics and additional dialects;
  complete platform behavior/native tests.

Eight decoder fixtures, one loader integration fixture and one prep regression are
written/unrun; 95 inputs. No protected key execution, sealed artifacts, installation,
renewal, UI readiness or native/platform-completion claim.

### Regular export trie subset (source only)

- [x] Canonical bounded trie decoding: regular/weak regular terminals, mapped
  pre-signature file addresses, unique edges/symbols and acyclic node ownership.
- [x] Bounded depth/nodes/names, disjoint complete coverage, no hidden/gap data.
- [x] Shared decoder for legacy and dedicated exports; nonempty alternate streams
  reject. Unsupported reexport/resolver/TLS/absolute flags reject.
- [ ] Chained fixups and remaining linkedit/platform semantics/native validation.

Six new fixtures, one updated integration fixture and one prep regression unrun;
97 input mappings. Metadata validation is not symbol availability/execution proof
or protected signing/install/refresh/UI authority. Default readiness remains shut.

### Chained-fixup subset (source only; platform behavior unvalidated)

- [x] Immutable Apple dyld fixup-chains.h ABI review, recorded revision/hash.
- [x] Uncompressed 64_OFFSET/import-v1 parsing: bounded/disjoint structures,
  canonical pool and positive 1...240 ordinals; no weak/special/addend forms.
- [x] Writable pre-signature page/pointer walks, mapped rebase/import targets,
  reserved-bit/type/alignment/duplicate/coverage/cancellation budgets.
- [x] Loader integration; nonempty classic pointer streams cannot coexist.
- [ ] Other fixup dialects/remaining linkedit semantics and native/device vectors.

Seven new fixtures plus updated loader case/one prep regression unrun; 99 inputs.
No runtime fixups, private key delegation, verified install artifact, install/
renewal/UI readiness or native platform-completion claim.

### Whole packaged-output read-only audit (source only)

- [x] Supported function-start and data-in-code metadata decoding, connected to loader.
- [x] Whole output composition: full archive CRC/resource consistency, image mutation/
  loader checks, dual claims, exact requirements, directory hashes and CMS signature.
- [x] Fresh input/identity/profile/certificate checks before AND after detached output
  work, shared proof hash matching, original deadline and retained worker lifetime.
- [ ] Native/trusted positive audit fixtures and platform/cross-payload acceptance.
- [ ] Protected key execution, private workspace and opaque install-artifact release;
  pairing/device install evidence, renewal and actual app/UI pipeline.

Audit returns metadata only, never bytes/URLs/keys or install authority. Four native
fixtures and one prep regression written/unrun, 102 inputs. Default CMS/capability
readiness unchanged; no native execution or end-to-end completion claim.

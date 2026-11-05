# Upstream feature review

**Reviewed: 6 November 2026.** This is a dated snapshot, not a live compatibility
or integration-status tracker. Recheck the source and VexSign implementation
before planning a port or describing an upstream feature as available.

At the review date, checked the latest default-branch commits and available release notes from the
following repositories. **This is an upstream watchlist, not a claim that every
change has been ported.** VexSign capabilities are described in the [README feature list](../README.md#features);
upstream fixes and performance claims need their own review, tests and device validation.

- **[Feather](https://github.com/claration/Feather/commit/31ab6de455f2a6108f6830e343dee826310c03be):** latest addition is the MikeBuilds Originals recommended source. Recent earlier changes include entitlement merging and minimum-iOS display before signing. At review time, MikeBuilds was **not yet in the reviewed checkout's recommended-source list**; VexSign's existing entitlement editor and IPA metadata viewer do not establish exact upstream parity.
- **[FeatherPlus](https://github.com/TomerGamerTV/FeatherPlus/commit/9af4713cf6d5c1db3a1f24ddabca53008a46ac5a):** latest head is release automation for v2.9.0 after an upstream merge. VexSign already has encrypted backup/restore; no additional newest-commit app feature is claimed here.
- **[Ksign](https://github.com/Nyasami/Ksign/commit/c14dedc0c9dadb669021cce83435b14f781b8412):** latest head changes its default installation method to semi-local; recent changes also cover Liquid Glass compatibility. VexSign exposes install-method and Liquid Glass controls, but this does not mean Ksign's defaults or exact patches are adopted.
- **[RyukSign](https://github.com/faroukbmiled/RyukSign/commit/844466cee6f212291913ba5216f8f19a9c016dea):** latest release work covers batch-install staging, delete-after-install/cache cleanup and bounds-checked dylib inspection. VexSign has corresponding cleanup and inspection components; upstream bug-fix equivalence still requires targeted verification.
- **[KorSign](https://github.com/korboybeats/KorSign/releases/tag/v3.0.1-r1):** latest release adds IPA-import pause/resume/stop, picker/haptic refinements and pairing/import optimizations. Its advertised speedups are **not VexSign benchmarks**; import controls and optimization parity are not claimed for VexSign.
- **[MySignReincarnated](https://github.com/gliddd4/MySignReincarnated/commit/c21554d69de8821d6fd3a323371badbeb7d764e0):** latest changes add a Downloads tab and refine tab-bar/description layout. VexSign has its own download interface and navigation; matching upstream layout fixes are not assumed.
- **[SideStore](https://github.com/SideStore/SideStore/commit/cd260851ae99bf1fc946b123db24e89c8cd21dc6):** latest head updates its SDK/runner, with preceding pairing and SideSign changes. These are reference inputs, not a VexSign SDK upgrade or proof of complete native account signing.
- **[LiveContainer](https://github.com/LiveContainer/LiveContainer/commit/9108ae624ea001f7d7696d48407f890b48fa2653):** latest head fixes upstream issues and bumps its version, following a Dead10ccFix memory-leak fix. VexSign's separate pinned host prototype does not automatically receive those changes.

SideStore and LiveContainer are separately licensed AGPL projects. This review
does not copy their code, change dependency pins or make optional integrations
production-ready. Dates refer to this review, not a guarantee of continuous sync.

[Back to VexSign](../README.md) · [Documentation index](README.md)

#!/usr/bin/env python3
"""Regression guard: user-facing network requests must be able to fail.

`URLSession.shared` has a 60-second default timeout and follows redirects. A request that never
sets its own bound therefore leaves a screen spinning with no error and no way to retry, for as
long as the session decides to wait — once per redirect hop, and once per page for a paginated
fetch. That is indistinguishable from a hang, and it is invisible in review because the request
looks ordinary.

The audit deliberately does *not* centralise these calls. They have different trust, redirect and
cancellation requirements, and unifying them would change behaviour that is not understood yet.
What is pinned here is only the property that matters for every one of them: a bounded wait.

Scope is deliberately narrow — the requests a person is waiting on while looking at a screen.
Background downloads set their own policy through `URLSessionConfiguration` and are not covered.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]

# (file, the line that must precede the request, why it is in scope)
BOUNDED_REQUESTS = [
    (
        "App/iOS/VexSign/Backend/Observable/SelfUpdateManager.swift",
        "URLRequest(url: finalURL)",
        "self-update release pages; the update screen waits on the first page",
    ),
    (
        "App/iOS/VexSign/Utilities/Services/RepositoryCatalogService.swift",
        "X-GitHub-Api-Version",
        "resolving a GitHub release source while a repository is being added",
    ),
    (
        "App/iOS/VexSign/Views/Sources/SourcesAddView+Repositories.swift",
        "VexSignAPI.reposListURL",
        "the repository catalog behind the add-source screen",
    ),
]


class NetworkRequestTimeoutPolicyTests(unittest.TestCase):
    def test_each_bounded_request_sets_a_timeout(self) -> None:
        for relative, marker, why in BOUNDED_REQUESTS:
            with self.subTest(file=relative):
                source = (ROOT / relative).read_text()
                # The request built from `marker` must have a timeout before it is sent.
                marker_at = source.find(marker)
                self.assertNotEqual(marker_at, -1, f"{relative}: expected {marker!r} to still exist")
                window = source[marker_at:marker_at + 1200]
                send = window.find("URLSession.shared.data")
                self.assertNotEqual(send, -1, f"{relative}: no request found after {marker!r}")
                self.assertIn(
                    "timeoutInterval",
                    window[:send],
                    f"{relative}: {why} has no timeout, so a stalled server hangs the screen",
                )

    def test_no_new_unbounded_request_appears_in_the_files_that_had_one(self) -> None:
        # A later edit should not add a second, unbounded call beside the bounded ones.
        for relative, _, why in BOUNDED_REQUESTS:
            with self.subTest(file=relative):
                source = (ROOT / relative).read_text()
                sends = [m.start() for m in re.finditer(r"URLSession\.shared\.data", source)]
                self.assertTrue(sends, f"{relative}: expected at least one request")
                for position in sends:
                    # Look back far enough to cover a request built and configured inline.
                    window = source[max(0, position - 1200):position]
                    self.assertIn(
                        "timeoutInterval",
                        window,
                        f"{relative}: an unbounded request was added ({why})",
                    )

    def test_cloud_signing_requests_that_are_reachable_are_bounded(self) -> None:
        # `signRemotely` is disabled (private-key upload refused), but `checkHealth` and `upload`
        # are reachable. Both are bounded: the JSON builder sets `timeoutInterval` on every
        # request it makes, and the upload session carries a resource timeout for a 2 GiB body.
        # The requests used to be assembled inline here, which is why this test looked for the
        # property inside the method; it now follows it to the builder instead.
        source = (ROOT / "App/iOS/VexSign/Backend/CloudSigning/CloudSigningClient.swift").read_text()
        start = source.find("func checkHealth()")
        self.assertNotEqual(start, -1, "checkHealth is the reachable cloud request")
        health = source[start:]
        end = health.find("\n\tfunc ", 10)   # the next method, not this declaration
        health = health[:end] if end != -1 else health
        self.assertRegex(health, r"timeout:\s*\d", "the cloud connection test must set its own bound")

        builder = source[source.find("private func _request("):]
        self.assertIn("request.timeoutInterval = timeout", builder,
                      "every cloud JSON request must carry the bound it was given")

        upload = source[source.find("func upload(fileURL:"):]
        upload = upload[:upload.find("\n\tfunc ", 10)]
        self.assertIn("timeoutIntervalForResource", source,
                      "a large upload needs a resource timeout, not just a request one")
        self.assertIn("uploadSession.upload", upload, "the upload must use the bounded session")

        self.assertIn("privateKeyUploadDisabled", source,
                      "if upload becomes enabled, its requests need timeouts too")


if __name__ == "__main__":
    unittest.main(verbosity=2)

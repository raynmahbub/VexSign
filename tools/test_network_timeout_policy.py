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

ROOT = Path(__file__).resolve().parents[1]

# (file, the line that must precede the request, why it is in scope)
BOUNDED_REQUESTS = [
    (
        "VexSign/Backend/Observable/SelfUpdateManager.swift",
        "URLRequest(url: finalURL)",
        "self-update release pages; the update screen waits on the first page",
    ),
    (
        "VexSign/Utilities/FR+Repository.swift",
        "X-GitHub-Api-Version",
        "resolving a GitHub release source while a repository is being added",
    ),
    (
        "VexSign/Views/Sources/SourcesAddView+Repositories.swift",
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
        # `signRemotely` is disabled (private-key upload refused), so the two request builders
        # that only it can reach are exempt. `checkHealth` is what the connection test uses and
        # it already carries a timeout; this keeps a future edit from dropping it.
        source = (ROOT / "VexSign/Backend/CloudSigning/CloudSigningClient.swift").read_text()
        start = source.find("func checkHealth()")
        self.assertNotEqual(start, -1, "checkHealth is the reachable cloud request")
        health = source[start:]
        end = health.find("\n\tfunc ", 10)   # the next method, not this declaration
        health = health[:end] if end != -1 else health
        self.assertIn("timeoutInterval", health, "the cloud connection test must be bounded")
        self.assertIn("privateKeyUploadDisabled", source,
                      "if upload becomes enabled, its requests need timeouts too")


if __name__ == "__main__":
    unittest.main(verbosity=2)

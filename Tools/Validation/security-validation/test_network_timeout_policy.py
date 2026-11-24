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

ROOT = Path(__file__).resolve().parents[3]

# (file, the line that must precede the request, why it is in scope)
BOUNDED_REQUESTS = [
    (
        "VexSign/Services/Updates/SelfUpdateManager.swift",
        "URLRequest(url: finalURL)",
        "self-update release pages; the update screen waits on the first page",
    ),
    (
        "VexSign/Services/Repository/RepositoryCatalogService.swift",
        "X-GitHub-Api-Version",
        "resolving a GitHub release source while a repository is being added",
    ),
    (
        "VexSign/Services/Repository/RepositoryDirectoryClient.swift",
        "VexSignAPI.reposListURL",
        "the repository catalog behind the add-source screen",
    ),
]


# A request is "sent" when it leaves through one of these. `BoundedResponseFetch` is the
# size-limited path (it streams to disk and stops at the caller's cap), so a call site that
# moved there is still a request whose wait must be bounded.
SEND_PATTERN = (
    r"(?:URLSession\.shared\.data"
    r"|session\.data"
    r"|session\.bytes"
    r"|session\.download"
    r"|BoundedResponseFetch\.fetch"
    r"|VexSignAPI\.performDataRequest)"
)


# ---------------------------------------------------------------------------
# Source scoping
#
# The property under test is "the request this line builds is bounded". The
# first version of this gate measured *characters* from the marker to the send
# and from the send back to `timeoutInterval`. That made comment length part of
# the contract: a four-line explanation above `let configuration` pushed a real
# request out of the window and the gate failed on a file that plainly sets its
# timeout. Scopes below are found by matching braces, so prose cannot move them.
# ---------------------------------------------------------------------------

_SWIFT_STRING_DELIMITERS = ('"""', '"')


def _skip_string(source: str, index: int) -> int:
    """Returns the index just past the string literal that starts at `index`."""
    for delimiter in _SWIFT_STRING_DELIMITERS:
        if source.startswith(delimiter, index):
            cursor = index + len(delimiter)
            while cursor < len(source):
                if source[cursor] == "\\":
                    cursor += 2
                    continue
                if source.startswith(delimiter, cursor):
                    return cursor + len(delimiter)
                cursor += 1
            return len(source)
    return index + 1


def _code_mask(source: str) -> list:
    """True for characters that are code, False inside comments and literals.

    Braces inside a log message or a JSON template must not open a scope, and
    a `//` inside a URL string must not start a comment, so both are tracked.
    """
    mask = [True] * len(source)
    index = 0
    length = len(source)
    while index < length:
        char = source[index]
        if char == "/" and source.startswith("//", index):
            end = source.find("\n", index)
            end = length if end == -1 else end
            for position in range(index, end):
                mask[position] = False
            index = end
            continue
        if char == "/" and source.startswith("/*", index):
            end = source.find("*/", index + 2)
            end = length if end == -1 else end + 2
            for position in range(index, end):
                mask[position] = False
            index = end
            continue
        if char == "\"":
            end = _skip_string(source, index)
            for position in range(index, end):
                mask[position] = False
            index = end
            continue
        index += 1
    return mask


def _blocks(source: str) -> list:
    """Every matched `{ ... }` span in `source`, as (open, close) indices."""
    mask = _code_mask(source)
    stack = []
    spans = []
    for index, char in enumerate(source):
        if not mask[index]:
            continue
        if char == "{":
            stack.append(index)
        elif char == "}" and stack:
            spans.append((stack.pop(), index))
    return spans


def enclosing_blocks(source: str, index: int) -> list:
    """Spans around `index`, innermost first, so a caller can walk outward."""
    spans = [span for span in _blocks(source) if span[0] < index < span[1]]
    return sorted(spans, key=lambda span: span[0], reverse=True)


def bounded_before(source: str, index: int) -> bool:
    """Whether `timeoutInterval` is set in code before `index`, in any scope.

    A timeout assigned in the function that builds the request, in a nested
    `do`/`for` inside it, or in the configuration that function constructs all
    count; one assigned in a *different* function does not.
    """
    mask = _code_mask(source)
    for start, _ in enclosing_blocks(source, index):
        window = source[start:index]
        for offset, char in enumerate(window):
            if char == "t" and window.startswith("timeoutInterval", offset) and mask[start + offset]:
                return True
    return False


class NetworkRequestTimeoutPolicyTests(unittest.TestCase):
    def test_each_bounded_request_sets_a_timeout(self) -> None:
        for relative, marker, why in BOUNDED_REQUESTS:
            with self.subTest(file=relative):
                source = (ROOT / relative).read_text()
                # The request built from `marker` must be bounded in the scope that
                # builds it. Scopes come from matched braces, so comment length and
                # formatting cannot move the assertion.
                marker_at = source.find(marker)
                self.assertNotEqual(marker_at, -1, f"{relative}: expected {marker!r} to still exist")
                scopes = enclosing_blocks(source, marker_at)
                self.assertTrue(scopes, f"{relative}: {marker!r} is not inside a scope")
                outermost = scopes[-1]
                match = re.search(SEND_PATTERN, source[marker_at:outermost[1]])
                self.assertIsNotNone(
                    match,
                    f"{relative}: no request found in the scope that builds {marker!r}",
                )
                send = marker_at + match.start()
                self.assertTrue(
                    bounded_before(source, send),
                    f"{relative}: {why} has no timeout, so a stalled server hangs the screen",
                )

    def test_no_new_unbounded_request_appears_in_the_files_that_had_one(self) -> None:
        # A later edit should not add a second, unbounded call beside the bounded ones.
        for relative, _, why in BOUNDED_REQUESTS:
            with self.subTest(file=relative):
                source = (ROOT / relative).read_text()
                sends = [m.start() for m in re.finditer(SEND_PATTERN, source)]
                self.assertTrue(sends, f"{relative}: expected at least one request")
                for position in sends:
                    line = source.count("\n", 0, position) + 1
                    self.assertTrue(
                        bounded_before(source, position),
                        f"{relative}:{line}: an unbounded request was added ({why})",
                    )

    def test_repository_traffic_uses_one_shared_budget(self) -> None:
        # The GitHub path had an explicit 20 s / 16 MB budget while the generic feed and the
        # download probe used `URLSession.shared` defaults. Both numbers now have one home, so a
        # new call site cannot invent a third policy (or none).
        catalog = (ROOT / "VexSign/Services/Repository/RepositoryCatalogService.swift").read_text()
        self.assertIn("enum RepositoryNetworkPolicy", catalog)
        self.assertIn("request.timeoutInterval = RepositoryNetworkPolicy.requestTimeout", catalog)
        self.assertIn("data.count <= RepositoryNetworkPolicy.maxFeedBytes", catalog)
        probe = (ROOT / "VexSign/Services/Repository/RepositoryDownloadProbe.swift").read_text()
        self.assertIn("RepositoryNetworkPolicy.probeTimeout", probe)
        self.assertIn("RepositoryNetworkPolicy.maxConcurrentProbes", probe)

    def test_directory_transport_keeps_redirect_credential_and_size_bounds(self) -> None:
        source = (ROOT / "VexSign/Services/Repository/RepositoryDirectoryClient.swift").read_text()
        for required in ("URLSessionConfiguration.ephemeral", "maximumBytes", "sameOrigin", "redirects <= 5", "X-API-Key", "try Task.checkCancellation()", "session.invalidateAndCancel()"):
            self.assertIn(required, source)
        ui = (ROOT / "App/Features/Sources/Views/SourcesAddView+Repositories.swift").read_text()
        self.assertNotIn("URLSession", ui, "transport must not move back into the screen")

    def test_cloud_signing_requests_that_are_reachable_are_bounded(self) -> None:
        # `signRemotely` is disabled (private-key upload refused), but `checkHealth` and `upload`
        # are reachable. Both are bounded: the JSON builder sets `timeoutInterval` on every
        # request it makes, and the upload session carries a resource timeout for a 2 GiB body.
        # The requests used to be assembled inline here, which is why this test looked for the
        # property inside the method; it now follows it to the builder instead.
        source = (ROOT / "VexSign/Services/Signing/Engines/Cloud/CloudSigningClient.swift").read_text()
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


class ScopeScannerTests(unittest.TestCase):
    """The scanner must see code, not prose, or every rule above is noise."""

    def test_brace_in_comment_does_not_open_a_scope(self) -> None:
        source = "func f() {\n    // a } brace in prose\n    send()\n}\n"
        spans = _blocks(source)
        self.assertEqual(len(spans), 1)
        self.assertEqual(source[spans[0][0]], "{")
        self.assertEqual(spans[0][1], source.rindex("}"))

    def test_brace_in_string_does_not_open_a_scope(self) -> None:
        source = 'func f() {\n    let s = "a } brace in a string"\n    send()\n}\n'
        self.assertEqual(len(_blocks(source)), 1)
        self.assertTrue(bounded_before('func f() { timeoutInterval = 2; send() }', 32))

    def test_timeout_in_another_function_does_not_count(self) -> None:
        source = (
            "func bounded() {\n    request.timeoutInterval = 20\n}\n"
            "func unbounded() {\n    send()\n}\n"
        )
        position = source.index("send()")
        self.assertFalse(bounded_before(source, position))

    def test_timeout_in_an_outer_scope_counts(self) -> None:
        source = (
            "func bounded() {\n    request.timeoutInterval = 20\n"
            "    for _ in 0 ..< 3 {\n        send()\n    }\n}\n"
        )
        position = source.index("send()")
        self.assertTrue(bounded_before(source, position))

    def test_url_with_slashes_is_not_read_as_a_comment(self) -> None:
        source = 'func f() {\n    let u = "https://host/path"\n    send()\n}\n'
        self.assertEqual(len(_blocks(source)), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)

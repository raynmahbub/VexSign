#!/usr/bin/env python3
"""Regression guard: the iOS cloud-signing client and the service it calls must agree.

`Services/CloudSigning/cloud-signing/openapi.json` is generated from the service's own zod schemas (`npm run contracts`)
and CI fails if the committed copy differs, so it is the contract rather than a description of
one. The iOS client decodes that contract into Swift structs by hand.

They were allowed to drift once: the client expected `{jobId}` from `POST /api/sign` and
`{status, progress, step, downloadUrl, error}` from `GET /api/jobs/{id}`, while the service sends
`JobAccepted` and a snake_case job row. Nothing failed until a real cluster answered, and then
every accepted submission failed to decode. Renaming a field on either side is still easy; this
check is what makes it visible.

It is deliberately a source check, not a compiled test: the Swift toolchain is not available in
every environment that runs this suite, and the property under test — "the wire names match" — is
visible in the text.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OPENAPI = ROOT / "Services/CloudSigning/cloud-signing/openapi.json"
CLIENT = ROOT / "App/iOS/VexSign/Backend/CloudSigning/CloudSigningClient.swift"
UPLOAD_BODY = ROOT / "App/iOS/VexSign/Backend/CloudSigning/CloudUploadBody.swift"
CONTRACT_TESTS = ROOT / "App/Tests/VexSignTests/CloudSigningContractTests.swift"

APP = (ROOT / "Services/CloudSigning/cloud-signing/src/app.ts").read_text()


def _schema() -> dict:
    return json.loads(OPENAPI.read_text())


def _properties(name: str) -> set[str]:
    return set(_schema()["components"]["schemas"][name]["properties"])


def _required(name: str) -> set[str]:
    return set(_schema()["components"]["schemas"][name].get("required", []))


def _swift_block(source: str, marker: str) -> str:
    """The body of the first `struct`/`enum`/`func` whose declaration contains `marker`."""
    start = source.index(marker)
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise AssertionError(f"unbalanced braces after {marker!r}")


def _code_only(source: str) -> str:
    """Drop comment lines: a doc comment may name a field it is explaining away."""
    return "\n".join(line for line in source.splitlines() if not line.lstrip().startswith("//"))


def _swift_properties(block: str) -> set[str]:
    return set(re.findall(r"^\tlet (\w+):", block, re.MULTILINE))


def _swift_wire_names(block: str) -> set[str]:
    """Properties plus the wire names of any `case local = "wire"` CodingKeys entries."""
    names = set(_swift_properties(block))
    for local, wire in re.findall(r"case\s+(\w+)\s*=\s*\"([^\"]+)\"", block):
        names.discard(local)
        names.add(wire)
    return names


class CloudSigningContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.client = CLIENT.read_text()
        self.upload = UPLOAD_BODY.read_text()

    # ---- The document is a real contract ------------------------------------------------

    def test_the_documented_endpoints_still_exist(self) -> None:
        paths = set(_schema()["paths"])
        for route in ("/api/upload", "/api/sign", "/api/jobs/{id}", "/api/queue"):
            self.assertIn(route, paths)

    def test_every_documented_error_response_uses_the_error_schema(self) -> None:
        # The client classifies failures from `{error, requestId}`; a route that answers a
        # different body would be classified by status alone and lose its request id.
        for route, operations in _schema()["paths"].items():
            for method, operation in operations.items():
                for status, response in operation.get("responses", {}).items():
                    if 400 <= int(status) < 600:
                        reference = response.get("content", {}).get("application/json", {}).get("schema", {}).get("$ref")
                        self.assertEqual(reference, "#/components/schemas/Error", f"{method.upper()} {route} {status}")

    # ---- Accepted submission ------------------------------------------------------------

    def test_the_client_decodes_the_documented_job_accepted_body(self) -> None:
        block = _swift_block(self.client, "struct CloudJobAccepted")
        self.assertTrue(_required("JobAccepted") <= _swift_wire_names(block))

    def test_the_client_sends_the_idempotency_key_the_service_requires(self) -> None:
        parameters = _schema()["paths"]["/api/sign"]["post"]["parameters"]
        self.assertIn("Idempotency-Key", {parameter["name"] for parameter in parameters if parameter.get("required")})
        block = _swift_block(self.client, "func submitSignJob")
        self.assertIn('forHTTPHeaderField: "Idempotency-Key"', block)
        # The key is a parameter, not something minted inside the request: reusing it across an
        # ambiguous failure is what makes the retry collapse onto the original job.
        self.assertRegex(block, r"idempotencyKey: String = UUID\(\)\.uuidString")

    # ---- Job view -----------------------------------------------------------------------

    def test_the_client_decodes_every_required_job_view_field(self) -> None:
        block = _swift_block(self.client, "struct CloudJob:")
        self.assertTrue(_required("JobView") <= _swift_wire_names(block), sorted(_required("JobView") - _swift_wire_names(block)))

    def test_the_client_does_not_decode_fields_the_service_never_sends(self) -> None:
        block = _swift_block(self.client, "struct CloudJob:")
        documented = _properties("JobView")
        invented = {name for name in _swift_wire_names(block) if name not in documented and name not in {"result", "errorCode", "outputSHA256", "installURLString", "createdAtString", "finishedAtString"}}
        self.assertEqual(invented, set())

    def test_the_stale_field_names_are_gone(self) -> None:
        # These are the names the guessed models used, checked outside comments: the header
        # names them on purpose, to record what was wrong. Their absence in code is the fix.
        code = _code_only(self.client)
        # `jobId:` as a *parameter* is fine; as a decoded property it was the bug.
        for stale in ('"jobId"', "CloudJobStatus", "downloadUrl", "let jobId:"):
            self.assertFalse(stale in code, f"stale field name {stale} is back")

    def test_the_fixture_the_tests_decode_matches_the_document(self) -> None:
        fixture = re.search(r'private let completedSignJob = #"""(.*?)"""#', CONTRACT_TESTS.read_text(), re.DOTALL)
        self.assertIsNotNone(fixture, "the job-view fixture moved; update this check with it")
        body = json.loads(fixture.group(1))
        self.assertTrue(_required("JobView") <= set(body))
        self.assertTrue(set(body) <= _properties("JobView"))

    # ---- Upload --------------------------------------------------------------------------

    def test_the_client_decodes_the_documented_upload_response(self) -> None:
        block = _swift_block(self.client, "struct CloudUploadResponse")
        schema = _schema()["paths"]["/api/upload"]["post"]["responses"]["201"]["content"]["application/json"]["schema"]
        self.assertTrue(set(schema["required"]) <= _swift_wire_names(block))

    def test_the_upload_sends_the_token_in_one_redacted_header(self) -> None:
        # The service verifies `Authorization` and redacts it from its access log. It ignores
        # `x-api-key` and does not redact it, so sending the token there wrote a credential into
        # the service's logs.
        self.assertIn('forHTTPHeaderField: "Authorization"', self.upload)
        self.assertNotIn('forHTTPHeaderField: "x-api-key"', self.upload)
        self.assertNotIn('forHTTPHeaderField: "x-api-key"', self.client)

    # ---- Transport -----------------------------------------------------------------------

    def test_every_cloud_request_is_bounded_in_time(self) -> None:
        request_block = _swift_block(self.client, "private func _request(")
        self.assertIn("request.timeoutInterval = timeout", request_block)
        self.assertIn("timeoutIntervalForResource", self.client)

    def test_only_the_idempotent_read_is_retried(self) -> None:
        self.assertEqual(self.client.count("shouldRetry(afterAttempt:"), 1)
        read_block = _swift_block(self.client, "func getJobStatus")
        self.assertIn("shouldRetry(afterAttempt: attempt, error: error, idempotent: true)", read_block)
        submit_block = _swift_block(self.client, "func submitSignJob")
        self.assertNotIn("shouldRetry", submit_block)

    def test_the_server_validates_the_job_view_before_sending_it(self) -> None:
        # The route returns a parsed `JobView`, so a renamed column fails in CI instead of in an
        # app: `jobView.parse(...)` is what makes the document above enforceable.
        self.assertIn("contract(jobView, 'JobView'", APP)
        self.assertIn("contract(queueCounts, 'QueueCounts'", APP)


if __name__ == "__main__":
    unittest.main(verbosity=2)

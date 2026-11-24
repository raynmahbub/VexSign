#!/usr/bin/env python3
"""Regression tests for the runtimes the two services are built, tested and shipped on.

CI tested Node 22 while `Services/Cloud/Dockerfile` shipped `node:25`, and tested Python
3.12 while `Services/WebManager/Dockerfile` shipped `python:3.15` and `render.yaml`
declared no version at all. Every one of those passed CI, because CI only ever validates the
runtime it was told to use: a green test run said nothing about the interpreter actually holding
the sealed signing passwords in production.

Node 25 is the sharp end of that. Odd-numbered Node releases are the "Current" line — they never
become LTS and stop receiving security patches roughly six months after launch — so the image was
running an unsupported runtime. `package.json` made it worse by pairing `engines: node >=22` with
`@types/node@^26`, which lets `npm run build` type-check an API that then fails at runtime on both
the tested and the shipped version.

Nothing here needs PyYAML: the workflow and blueprint values are read with the same narrow regexes
the rest of this suite uses.
"""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CLOUD = ROOT / "Services/Cloud"
WEBMANAGER = ROOT / "Services/WebManager"
WORKFLOWS = ROOT / ".github/workflows"


def docker_base_images(dockerfile: Path) -> list[tuple[str, str]]:
    """Every `FROM` line as (image, tag). An untagged `FROM` yields an empty tag."""
    found = []
    for line in dockerfile.read_text(encoding="utf-8").splitlines():
        match = re.match(r"\s*FROM\s+(?:--platform=\S+\s+)?([A-Za-z0-9._/-]+)(?::([^\s]+))?", line)
        if match:
            found.append((match.group(1), match.group(2) or ""))
    return found


def workflow_versions(key: str) -> dict[str, list[str]]:
    """Every `node-version:` / `python-version:` declared in any workflow, by workflow name.

    All of them, not just `services.yml`: Python is pinned in four workflows, so checking one
    would let a partial bump reintroduce exactly the drift this file exists to prevent.
    """
    found: dict[str, list[str]] = {}
    for path in sorted(WORKFLOWS.glob("*.yml")):
        values = re.findall(rf"^\s*{key}:\s*['\"]?([0-9.]+)['\"]?\s*$",
                            path.read_text(encoding="utf-8"), re.MULTILINE)
        if values:
            found[path.name] = values
    assert found, f"no workflow declares {key}"
    return found


def flat(key: str) -> set[str]:
    return {value for values in workflow_versions(key).values() for value in values}


def blueprint_env(name: str) -> str | None:
    """The committed `value:` of one render.yaml env var, or None if it is dashboard-only."""
    text = (ROOT / "Services/WebManager/Configuration/render.yaml").read_text(encoding="utf-8")
    match = re.search(rf"-\s*key:\s*{name}\s*\n\s*value:\s*['\"]?([^'\"\n]+)", text)
    return match.group(1).strip() if match else None


class CloudRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.images = docker_base_images(CLOUD / "Dockerfile")
        self.package = json.loads((ROOT / "Services/Cloud/package.json").read_text(encoding="utf-8"))
        self.majors = {int(re.match(r"(\d+)", tag).group(1)) for _, tag in self.images if tag}

    def test_the_image_runs_the_lts_line_ci_tests(self):
        # Both stages: a build stage on one major and a runtime stage on another reproduces the
        # original drift inside a single file.
        self.assertEqual({22}, self.majors, "every FROM in Cloud/Dockerfile must pin one Node major")
        declared = flat("node-version")
        self.assertEqual(1, len(declared), f"workflows disagree about Node: {workflow_versions('node-version')}")
        self.assertEqual(str(next(iter(self.majors))), declared.pop())

    def test_node_major_is_an_lts_line_not_a_current_release(self):
        for major in self.majors:
            self.assertEqual(0, major % 2,
                             f"node:{major} is an odd-numbered Current release; use the even LTS line")

    def test_declared_types_and_engine_floor_match_the_runtime(self):
        engines = self.package["engines"]["node"]
        floor = re.search(r"(\d+)", engines)
        self.assertIsNotNone(floor, engines)
        self.assertEqual(22, int(floor.group(1)), f"engines.node is {engines!r}")
        types = self.package["devDependencies"]["@types/node"]
        self.assertEqual(22, int(re.match(r"\D*(\d+)", types).group(1)),
                         f"@types/node is {types!r}: `npm run build` would type-check APIs the "
                         "shipped runtime does not have")


class WebManagerRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.images = docker_base_images(WEBMANAGER / "Dockerfile")

    def docker_python(self) -> str:
        versions = [re.match(r"(\d+\.\d+)", tag).group(1) for image, tag in self.images
                    if image.endswith("python") and tag]
        self.assertEqual(1, len(versions), f"expected one python base image, got {self.images}")
        return versions[0]

    def test_every_workflow_pins_the_interpreter_the_image_ships(self):
        declared = flat("python-version")
        self.assertEqual(1, len(declared),
                         f"workflows disagree about Python: {workflow_versions('python-version')}")
        self.assertEqual(self.docker_python(), declared.pop())

    def test_the_blueprint_pins_the_same_interpreter(self):
        # `runtime: python` with no version left Render to choose, so the hosted deployment was a
        # third runtime beside the image and the test job.
        self.assertEqual(self.docker_python(), blueprint_env("PYTHON_VERSION"),
                         "render.yaml must pin PYTHON_VERSION to the version CI and the image use")


class BaseImageHygieneTests(unittest.TestCase):
    def test_no_base_image_floats_on_latest_or_no_tag(self):
        for dockerfile in (CLOUD / "Dockerfile", WEBMANAGER / "Dockerfile"):
            for image, tag in docker_base_images(dockerfile):
                self.assertTrue(tag, f"{dockerfile.name}: `FROM {image}` has no tag")
                self.assertNotEqual("latest", tag, f"{dockerfile.name}: `FROM {image}:latest` floats")

    def test_every_from_line_was_parsed(self):
        # A guard on the guard: if the regex silently stops matching, the tests above would pass on
        # an empty list.
        for dockerfile in (CLOUD / "Dockerfile", WEBMANAGER / "Dockerfile"):
            declared = sum(1 for line in dockerfile.read_text(encoding="utf-8").splitlines()
                           if line.strip().upper().startswith("FROM "))
            self.assertEqual(declared, len(docker_base_images(dockerfile)), dockerfile.name)
            self.assertGreater(declared, 0, dockerfile.name)


if __name__ == "__main__":
    unittest.main()

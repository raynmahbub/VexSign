#!/usr/bin/env python3
"""Offline safety tests for the CI repair assistant's patch boundary."""
import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).with_name('ci_repair_agent.py')
spec = importlib.util.spec_from_file_location('ci_repair_agent', SCRIPT)
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


def patch(path='VexSign/App/Example.swift', body='@@ -1 +1 @@\n-old\n+new'):
    return (
        f'diff --git a/{path} b/{path}\n'
        f'index 1111111..2222222 100644\n'
        f'--- a/{path}\n'
        f'+++ b/{path}\n'
        f'{body}\n'
    )


class RepairPatchSafetyTests(unittest.TestCase):
    def test_accepts_a_modified_swift_file_from_the_pr_allowlist(self):
        self.assertEqual(
            agent.validate_patch(patch(), {'VexSign/App/Example.swift'}),
            {'VexSign/App/Example.swift'},
        )

    def test_accepts_only_opted_in_feature_presentation(self):
        for feature in ('Downloads', 'Sources', 'Tasks'):
            for area in ('Views', 'ViewModels'):
                path = f'VexSign/Features/{feature}/{area}/Example.swift'
                with self.subTest(path=path):
                    self.assertEqual(agent.validate_patch(patch(path), {path}), {path})
                    with self.assertRaises(ValueError):
                        agent.validate_patch(patch(path), set())

    def test_rejects_sensitive_areas_even_when_pr_allowlisted(self):
        paths = [
            'VexSign/Features/Signing/Views/Example.swift',
            'VexSign/Features/Accounts/ViewModels/Example.swift',
            'VexSign/Features/Certificates/Views/Example.swift',
            'VexSign/Features/Installation/Views/Example.swift',
            'VexSign/Features/Backup/Views/Example.swift',
            'VexSign/Features/Settings/Views/Security/Example.swift',
            'VexSign/Features/Sources/UseCases/Example.swift',
            'VexSign/Features/Sources/Views/CredentialEditor.swift',
            'VexSign/Features/Downloads/ViewModels/SigningModel.swift',
            'VexSign/Security/Policies/Example.swift',
            'VexSign/App/Credentials.swift',
            'VexSignTests/SecurityTests/Example.swift',
            'Packages/SideSign/Package.swift',
            'VexSign/Features//Sources/Views/Example.swift',
            'VexSign/Features/Sources/Views/../Example.swift',
            'VexSign/Features/Sources/Views/Example.swift/extra',
        ]
        for path in paths:
            with self.subTest(path=path), self.assertRaises(ValueError):
                agent.validate_patch(patch(path), {path})

    def test_rejects_files_outside_the_original_pr_allowlist(self):
        with self.assertRaisesRegex(ValueError, 'outside the allowed'):
            agent.validate_patch(patch('VexSign/App/Unrelated.swift'), {'VexSign/App/Example.swift'})

    def test_rejects_workflows_tools_and_non_swift_resources(self):
        for path in ('.github/workflows/ci.yml', 'Tools/build.py', 'Config/BuildSettings/iOS/Info.plist'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                agent.validate_patch(patch(path), {path})

    def test_rejects_path_traversal_and_absolute_paths(self):
        for path in ('VexSign/App/../.github/workflows/ci.yml', '/tmp/Evil.swift'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                agent.validate_patch(patch(path), {path})

    def test_rejects_file_additions_deletions_renames_mode_changes_and_binary_patches(self):
        additions = patch(body='new file mode 100644\n--- /dev/null\n+++ b/VexSign/App/Example.swift\n+code')
        deletions = patch(body='deleted file mode 100644\n--- a/VexSign/App/Example.swift\n+++ /dev/null\n-code')
        renames = patch(body='rename from VexSign/App/Example.swift\nrename to VexSign/App/Other.swift')
        mode_changes = patch(body='old mode 100644\nnew mode 120000')
        binary = patch(body='GIT binary patch\nliteral 0')
        for candidate in (additions, deletions, renames, mode_changes, binary):
            with self.subTest(candidate=candidate[:40]), self.assertRaises(ValueError):
                agent.validate_patch(candidate, {'VexSign/App/Example.swift'})

    def test_redacts_credential_shaped_ci_log_values(self):
        result = agent._redact_log("Authorization: Bearer secret-value\\nAPI_KEY=secret-value")
        self.assertNotIn("secret-value", result)
        self.assertIn("[REDACTED]", result)

    def test_rejects_malformed_and_oversized_patches(self):
        with self.assertRaises(ValueError):
            agent.validate_patch('not a diff', {'VexSign/App/Example.swift'})
        too_many_lines = patch(body='@@ -1 +1 @@\n' + '\n'.join(['-old', '+new'] * 401))
        with self.assertRaisesRegex(ValueError, 'line change limit'):
            agent.validate_patch(too_many_lines, {'VexSign/App/Example.swift'})
        with self.assertRaisesRegex(ValueError, '80 KB'):
            agent.validate_patch('x' * (agent.MAX_PATCH_BYTES + 1), {'VexSign/App/Example.swift'})


if __name__ == '__main__':
    unittest.main()

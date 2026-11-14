#!/usr/bin/env python3
"""Offline safety tests for the CI repair assistant's patch boundary."""
import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).with_name('ci_repair_agent.py')
spec = importlib.util.spec_from_file_location('ci_repair_agent', SCRIPT)
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


def patch(path='App/iOS/VexSign/Example.swift', body='@@ -1 +1 @@\n-old\n+new'):
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
            agent.validate_patch(patch(), {'App/iOS/VexSign/Example.swift'}),
            {'App/iOS/VexSign/Example.swift'},
        )

    def test_rejects_files_outside_the_original_pr_allowlist(self):
        with self.assertRaisesRegex(ValueError, 'outside the allowed'):
            agent.validate_patch(patch('App/iOS/VexSign/Unrelated.swift'), {'App/iOS/VexSign/Example.swift'})

    def test_rejects_workflows_tools_and_non_swift_resources(self):
        for path in ('.github/workflows/ci.yml', 'Tools/build.py', 'App/iOS/VexSign/Resources/Info.plist'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                agent.validate_patch(patch(path), {path})

    def test_rejects_path_traversal_and_absolute_paths(self):
        for path in ('App/iOS/VexSign/../.github/workflows/ci.yml', '/tmp/Evil.swift'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                agent.validate_patch(patch(path), {path})

    def test_rejects_file_additions_deletions_renames_mode_changes_and_binary_patches(self):
        additions = patch(body='new file mode 100644\n--- /dev/null\n+++ b/App/iOS/VexSign/Example.swift\n+code')
        deletions = patch(body='deleted file mode 100644\n--- a/App/iOS/VexSign/Example.swift\n+++ /dev/null\n-code')
        renames = patch(body='rename from App/iOS/VexSign/Example.swift\nrename to App/iOS/VexSign/Other.swift')
        mode_changes = patch(body='old mode 100644\nnew mode 120000')
        binary = patch(body='GIT binary patch\nliteral 0')
        for candidate in (additions, deletions, renames, mode_changes, binary):
            with self.subTest(candidate=candidate[:40]), self.assertRaises(ValueError):
                agent.validate_patch(candidate, {'App/iOS/VexSign/Example.swift'})

    def test_redacts_credential_shaped_ci_log_values(self):
        result = agent._redact_log("Authorization: Bearer secret-value\\nAPI_KEY=secret-value")
        self.assertNotIn("secret-value", result)
        self.assertIn("[REDACTED]", result)

    def test_rejects_malformed_and_oversized_patches(self):
        with self.assertRaises(ValueError):
            agent.validate_patch('not a diff', {'App/iOS/VexSign/Example.swift'})
        too_many_lines = patch(body='@@ -1 +1 @@\n' + '\n'.join(['-old', '+new'] * 401))
        with self.assertRaisesRegex(ValueError, 'line change limit'):
            agent.validate_patch(too_many_lines, {'App/iOS/VexSign/Example.swift'})
        with self.assertRaisesRegex(ValueError, '80 KB'):
            agent.validate_patch('x' * (agent.MAX_PATCH_BYTES + 1), {'App/iOS/VexSign/Example.swift'})


if __name__ == '__main__':
    unittest.main()

import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location('fixtures', Path(__file__).with_name('performance-fixtures.py'))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


class FixturesTests(unittest.TestCase):
    def test_deterministic_bounded_and_non_installable(self):
        with tempfile.TemporaryDirectory() as directory:
            first = fixtures.generate(Path(directory) / 'a', 1, 10, 20)
            second = fixtures.generate(Path(directory) / 'b', 1, 10, 20)
            self.assertEqual(first, second)
            self.assertFalse(first['installable'])
            for row in first['fixtures']:
                with zipfile.ZipFile(Path(directory) / 'a' / row['file']) as archive:
                    self.assertIsNone(archive.testzip())
                    self.assertEqual(len(archive.namelist()), len(set(archive.namelist())))
            result = fixtures.benchmark(Path(directory) / 'a', 2)
            self.assertFalse(result['ios_verified'])
            self.assertEqual(len(result['results']), 3)
            self.assertTrue(all(len(row['samples_seconds']) == 2 for row in result['results']))
            with self.assertRaises(FileExistsError):
                fixtures.generate(Path(directory) / 'a', 1, 10, 20)


if __name__ == '__main__':
    unittest.main()

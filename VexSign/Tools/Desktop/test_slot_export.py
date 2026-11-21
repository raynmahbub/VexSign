from pathlib import Path
import tempfile
import unittest

from slot_export import run


class SlotExportTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.folder = Path(tmp.name) / 'snapshot'
        self.device = {'Documents/test.zip': b'app export'}
        self.args = ('01234567', 'org.example.fixture', self.folder)

    def copy(self, direction, device, bundle, src, dst):
        if direction == 'to':
            self.assertNotIn(dst, self.device)
            self.device[dst] = src.read_bytes()
        else:
            dst.write_bytes(self.device[src])

    def backup(self):
        run('backup', *self.args, name='test.zip', copy=self.copy)

    def test_restore_verifies_new_file_without_replacing_original(self):
        self.backup()
        run('restore', *self.args, confirm=True, copy=self.copy)
        self.assertEqual(len(self.device), 2)
        self.assertEqual(set(self.device.values()), {b'app export'})

    def test_refuse_wrong_device_damaged_archive_and_unconfirmed_restore(self):
        self.backup()
        for args, confirm in [(self.args, False), (('87654321', *self.args[1:]), True)]:
            with self.assertRaises(ValueError):
                run('restore', *args, confirm=confirm, copy=self.copy)
        (self.folder / 'payload').write_bytes(b'corrupted')
        with self.assertRaises(ValueError):
            run('restore', *self.args, confirm=True, copy=self.copy)
        self.assertEqual(len(self.device), 1)

    def test_failed_backup_is_not_published(self):
        def unstable(direction, device, bundle, src, dst):
            dst.write_bytes(b'first' if dst.name == 'payload' else b'second')
        with self.assertRaises(ValueError):
            run('backup', *self.args, name='test.zip', copy=unstable)
        self.assertFalse(self.folder.exists())
        with self.assertRaises(ValueError):
            run('backup', *self.args, name='../Library', copy=self.copy)


if __name__ == '__main__':
    unittest.main()

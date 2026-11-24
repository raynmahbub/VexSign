import datetime
import hashlib
import io
import plistlib
import unittest
import zipfile
from unittest.mock import Mock

from observation import convert


class ObservationTests(unittest.TestCase):
    def setUp(self):
        self.ipa = io.BytesIO()
        with zipfile.ZipFile(self.ipa, 'w') as z:
            z.writestr('Payload/Test.app/Info.plist', plistlib.dumps({'CFBundleIdentifier': 'org.example.test'}))
            z.writestr('Payload/Test.app/embedded.mobileprovision', b'fixture')
        self.row = dict(bundle_id='org.example.test', profile_sha256=hashlib.sha256(b'fixture').hexdigest(), marker_sha256='a'*64)
        self.decode = Mock(return_value=plistlib.dumps(dict(TeamIdentifier=['ABCDEFGHIJ'], ExpirationDate=datetime.datetime(2026, 12, 1))))

    def test_matching_installed_artifact(self):
        result = convert(self.row, self.ipa, self.decode)
        self.assertEqual(result, dict(bundle_id=self.row['bundle_id'], marker_sha256='a'*64,
                                      team_id='ABCDEFGHIJ', profile_expires_utc='2026-12-01T00:00:00Z'))
        self.decode.assert_called_once_with(b'fixture')

    def test_wrong_artifact_not_decoded(self):
        for change in [dict(bundle_id='org.example.other'), dict(profile_sha256='b'*64), dict(marker_sha256='')]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                convert({**self.row, **change}, self.ipa, self.decode)
        self.decode.assert_not_called()


if __name__ == '__main__':
    unittest.main()

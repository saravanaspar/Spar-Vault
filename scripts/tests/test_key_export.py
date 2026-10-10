"""Run browser key-file regression tests without third-party dependencies."""
from pathlib import Path
import shutil
import subprocess
import unittest


class KeyExportTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), 'Node.js is needed for browser regression tests')
    def test_browser_key_export(self):
        result = subprocess.run(
            ['node', '--test', str(Path(__file__).with_name('key_export_test.cjs'))],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()

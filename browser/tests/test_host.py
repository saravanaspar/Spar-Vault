import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
spec=importlib.util.spec_from_file_location('host',Path(__file__).parents[1]/'host.py')
host=importlib.util.module_from_spec(spec);spec.loader.exec_module(host)
class HostTests(unittest.TestCase):
    def test_round_trip_and_bounds(self):
        s=io.BytesIO();host.write_frame(s,{'nonce':'a'*32,'origin':'https://example.test'});s.seek(0)
        self.assertEqual(host.read_frame(s)['nonce'],'a'*32)
        for data in [b'\x01',struct.pack('<I',8193),struct.pack('<I',2)+b'{']:
            with self.assertRaises(ValueError):host.read_frame(io.BytesIO(data))
    def test_private_state_rejects_world_readable_and_symlink(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'state';p.write_text('{}');p.chmod(0o600);self.assertEqual(host.private_json(p),{})
            if os.name!='nt':
                p.chmod(0o644)
                with self.assertRaises(ValueError):host.private_json(p)
                p.chmod(0o600);link=Path(d)/'link';link.symlink_to(p)
                with self.assertRaises(ValueError):host.private_json(link)
    def test_caller_and_origin_rejected_before_connect(self):
        config={'extensionId':'a'*32,'stateFile':'missing'}
        request={'nonce':'b'*32,'origin':'https://example.test'}
        with self.assertRaises(ValueError):host.handle(request,config,'chrome-extension://'+'c'*32+'/')
        for origin in ['http://example.test','https://example.test/path','https://user:pass@example.test','https://example.test?query']:
            with self.assertRaises(ValueError):host.handle({**request,'origin':origin},config,'chrome-extension://'+'a'*32+'/')
if __name__=='__main__':unittest.main()

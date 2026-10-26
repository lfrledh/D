from pathlib import Path
import importlib.util, plistlib, struct, sys, tempfile, unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Backends/Audio/Packaging'))
import package_audio_app as signing
spec=importlib.util.spec_from_file_location('resources_helper_test',ROOT/'scripts/prepare-development-resources.py')
resources=importlib.util.module_from_spec(spec);spec.loader.exec_module(resources)

class HelperSandboxTests(unittest.TestCase):
    def thin(self, executable=True):
        return b'\xcf\xfa\xed\xfe'+struct.pack('<III',0x100000c,0,2 if executable else 6)+b'\0'*16
    def universal(self, order, kinds):
        magic=b'\xca\xfe\xba\xbe' if order=='>' else b'\xbe\xba\xfe\xca'
        table=b''.join(struct.pack(order+'IIIII',0x100000c,0,128+i*32,32,0) for i in range(len(kinds)))
        return (magic+struct.pack(order+'I',len(kinds))+table).ljust(128,b'\0')+b''.join(self.thin(x) for x in kinds)
    def test_thin_and_both_universal_byte_orders(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'helper'
            for raw,expected in [(self.thin(),True),(self.thin(False),False),(self.universal('>',[True,True]),True),(self.universal('<',[True,True]),True)]:
                p.write_bytes(raw);self.assertEqual(signing._is_executable_mach_o(p),expected)
            p.write_bytes(self.universal('<',[True,False]))
            with self.assertRaises(signing.PackagingError):signing._is_executable_mach_o(p)
    def test_prepared_gate_reads_actual_entitlements(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'helper';p.write_bytes(self.thin())
            expected={'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True}
            for bad in [{},{'com.apple.security.app-sandbox':True},{**expected,'com.apple.security.get-task-allow':True}]:
                with patch.object(signing,'_entitlements',return_value=(bad,b'')),self.assertRaises(resources.ResourceError):
                    resources.check_helper_sandboxes(Path(folder))
            with patch.object(signing,'_entitlements',return_value=(expected,plistlib.dumps(expected))):
                self.assertEqual(resources.check_helper_sandboxes(Path(folder)),['helper'])
if __name__=='__main__':unittest.main()

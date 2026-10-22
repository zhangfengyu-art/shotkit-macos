import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('installer',Path(__file__).parents[1]/'scripts/install.py')
installer=importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)

class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.root=Path(self.temp.name)
        self.app=self.root/'source/ShotKit.app'; (self.app/'Contents/MacOS').mkdir(parents=True); (self.app/'Contents/MacOS/ShotKit').write_bytes(b'native-v5')
        self.target=self.root/'Applications/ShotKit.app'; self.config=self.root/'hammerspoon'; self.config.mkdir()
        self.original='-- unrelated automation\nlocal other = require("other")\nrequire("screenshot").start()\n\n-- Keep this unrelated module comment\nother.start()\n'
        (self.config/'init.lua').write_text(self.original)
        (self.config/'screenshot-data').mkdir(); (self.config/'screenshot-data/keep.png').write_bytes(b'private-history')
        self.verify=patch.object(installer,'verify_app'); self.verify.start()
        self.stop=patch.object(installer,'stop_legacy',return_value=True); self.stop_mock=self.stop.start()
    def tearDown(self):
        self.verify.stop(); self.stop.stop(); self.temp.cleanup()
    def install(self,**kw): return installer.install(self.app,self.target,self.config,**kw)
    def test_native_install_never_modifies_hammerspoon_without_migration(self):
        self.install(); self.assertEqual((self.config/'init.lua').read_text(),self.original); self.stop_mock.assert_not_called(); self.assertTrue((self.target/'Contents/MacOS/ShotKit').is_file())
    def test_scoped_migration_preserves_unrelated_scripts_and_history(self):
        result=self.install(migrate=True)
        self.assertEqual((self.config/'init.lua').read_text(),self.original.replace('require("screenshot").start()',installer.MARKER))
        self.assertEqual((self.config/'screenshot-data/keep.png').read_bytes(),b'private-history')
        self.assertEqual((Path(result['backup'])/'init.lua').read_text(),self.original)
        self.assertTrue(result['legacy_runtime_stopped'])
    def test_dry_run_has_no_mutation_or_runtime_stop(self):
        self.install(migrate=True,dry_run=True); self.assertFalse(self.target.exists()); self.stop_mock.assert_not_called(); self.assertEqual((self.config/'init.lua').read_text(),self.original)
    def test_restore_retains_history_and_restores_prior_app(self):
        self.target.mkdir(parents=True); (self.target/'old').write_bytes(b'old')
        self.install(migrate=True); installer.restore(self.target)
        self.assertEqual((self.target/'old').read_bytes(),b'old'); self.assertEqual((self.config/'init.lua').read_text(),self.original); self.assertTrue((self.config/'screenshot-data/keep.png').exists())
    def test_edited_init_is_not_overwritten_on_restore(self):
        self.install(migrate=True); init=self.config/'init.lua'; init.write_text(init.read_text()+'-- later user edit\n')
        with self.assertRaisesRegex(RuntimeError,'init.lua changed'): installer.restore(self.target)
        self.assertTrue(self.target.exists()); self.assertIn('later user edit',init.read_text())
    def test_symlink_is_rejected_without_changing_external_file(self):
        outside=self.root/'other.lua'; outside.write_text(self.original); (self.config/'init.lua').unlink(); (self.config/'init.lua').symlink_to(outside)
        with self.assertRaisesRegex(RuntimeError,'symlink'): self.install(migrate=True)
        self.assertEqual(outside.read_text(),self.original); self.assertFalse(self.target.exists())
    def test_unrecognized_start_statement_rejected(self):
        (self.config/'init.lua').write_text('local s=require("screenshot"); s.start()\n')
        with self.assertRaisesRegex(RuntimeError,'Unrecognized'): self.install(migrate=True)
        self.assertFalse(self.target.exists())
    def test_copy_failure_restores_init_and_previous_app(self):
        self.target.mkdir(parents=True); (self.target/'old').write_bytes(b'old')
        real_copy=installer.shutil.copytree
        def failing(source,dest,*a,**kw):
            if Path(source)==self.app: raise OSError('test copy failure')
            return real_copy(source,dest,*a,**kw)
        with patch.object(installer.shutil,'copytree',side_effect=failing),self.assertRaises(OSError):self.install(migrate=True)
        self.assertEqual((self.target/'old').read_bytes(),b'old'); self.assertEqual((self.config/'init.lua').read_text(),self.original)

if __name__=='__main__':unittest.main()

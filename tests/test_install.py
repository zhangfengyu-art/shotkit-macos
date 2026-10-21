import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('shotkit_install', Path(__file__).resolve().parents[1] / 'scripts/install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.config = self.base / 'config'
        self.app = self.base / 'ShotKit.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/MacOS/ShotKit').write_text('synthetic helper')
        verifier = patch.object(installer, 'verify_app')
        verifier.start()
        self.addCleanup(verifier.stop)

    def test_dry_run_does_not_create_config(self):
        result = installer.install(self.config, self.app, dry_run=True)
        self.assertTrue(result['dry_run'])
        self.assertFalse(self.config.exists())

    def test_existing_files_and_history_survive_round_trip(self):
        self.config.mkdir()
        original = '-- My settings\nrequire("unrelated").start()\n'
        (self.config / 'init.lua').write_text(original)
        (self.config / 'screenshot.lua').write_text('previous version')
        (self.config / 'screenshot-data').mkdir()
        shot = self.config / 'screenshot-data/private.png'
        shot.write_bytes(b'private synthetic fixture')
        installer.install(self.config, self.app)
        self.assertIn(original.rstrip(), (self.config / 'init.lua').read_text())
        installer.uninstall(self.config)
        self.assertEqual((self.config / 'init.lua').read_text(), original)
        self.assertEqual((self.config / 'screenshot.lua').read_text(), 'previous version')
        self.assertEqual(shot.read_bytes(), b'private synthetic fixture')
        self.assertFalse((self.config / 'ShotKit.app').exists())

    def test_user_edits_after_install_are_not_overwritten(self):
        installer.install(self.config, self.app)
        (self.config / 'screenshot.lua').write_text('user changes')
        before = (self.config / 'init.lua').read_text()
        with self.assertRaises(RuntimeError):
            installer.uninstall(self.config)
        self.assertEqual((self.config / 'screenshot.lua').read_text(), 'user changes')
        self.assertEqual((self.config / 'init.lua').read_text(), before)

    def test_user_init_additions_survive_uninstall(self):
        installer.install(self.config, self.app)
        init = self.config / 'init.lua'
        init.write_text(init.read_text() + '\n-- A later personal setting\n')
        installer.uninstall(self.config)
        self.assertIn('-- A later personal setting', init.read_text())
        self.assertNotIn('-- BEGIN SHOTKIT', init.read_text())

    def test_repeated_install_is_idempotent_and_can_restore_previous_version(self):
        installer.install(self.config, self.app)
        installer.install(self.config, self.app)
        self.assertEqual((self.config / 'init.lua').read_text().count('-- BEGIN SHOTKIT'), 1)
        installer.uninstall(self.config)
        self.assertTrue((self.config / 'ShotKit.app').exists())
        installer.uninstall(self.config)
        self.assertFalse((self.config / 'ShotKit.app').exists())

    def test_linked_init_requires_manual_install(self):
        self.config.mkdir()
        personal = self.base / 'personal.lua'
        personal.write_text('-- Keep me')
        (self.config / 'init.lua').symlink_to(personal)
        with self.assertRaises(RuntimeError):
            installer.install(self.config, self.app)
        self.assertEqual(personal.read_text(), '-- Keep me')
        installer.install(self.config, self.app, no_init=True)
        self.assertTrue((self.config / 'init.lua').is_symlink())


if __name__ == '__main__':
    unittest.main()

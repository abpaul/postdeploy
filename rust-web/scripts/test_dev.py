import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class LocalDevelopment(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        self.script = self.root / "scripts/dev.sh"
        shutil.copyfile(Path(__file__).with_name("dev.sh"), self.script)
        self.credentials = self.root / "config/credentials"
        self.credentials.mkdir(parents=True)
        (self.credentials / "development.toml.enc").write_text("sealed fixture")
        (self.credentials / "development.key").write_text("fixture key")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        cargo = self.bin / "cargo"
        cargo.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "from pathlib import Path\n"
            "Path('invocation.json').write_text(json.dumps({'args': sys.argv[1:], "
            "'cwd': os.getcwd(), 'env': {key: os.environ.get(key) for key in "
            "('DATABASE_URL', 'CREDSEAL_KEY_FILE', 'POSTDEPLOY_STORAGE_PREFIX')}}))\n"
            "sys.exit(int(os.environ.get('CARGO_EXIT', '0')))\n"
        )
        cargo.chmod(0o755)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("POSTDEPLOY_", "CREDSEAL_", "CARGO_"))
                    and key != "DATABASE_URL"}
        self.env["PATH"] = f"{self.bin}{os.pathsep}{self.env['PATH']}"

    def run_dev(self, **overrides):
        return subprocess.run(
            ["sh", str(self.script)], cwd=self.root.parent,
            env={**self.env, **overrides}, capture_output=True, text=True,
        )

    def test_starts_from_another_directory_with_persistent_private_data(self):
        result = self.run_dev(DATABASE_URL="sqlite://production.db")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = json.loads((self.root / "invocation.json").read_text())
        self.assertEqual(call["args"], ["run", "--locked", "--bin", "postdeploy-cli",
                                        "--", "start", "--environment", "development"])
        self.assertEqual(Path(call["cwd"]), self.root.resolve())
        self.assertEqual(call["env"]["DATABASE_URL"],
                         f"sqlite://{self.root.resolve()}/data/development/control.sqlite?mode=rwc")
        self.assertEqual(call["env"]["CREDSEAL_KEY_FILE"], "config/credentials/development.key")
        self.assertEqual(call["env"]["POSTDEPLOY_STORAGE_PREFIX"], "local-verification/dev/")
        self.assertEqual((self.root / "data/development").stat().st_mode & 0o777, 0o700)

    def test_missing_credentials_explains_setup_without_starting(self):
        (self.credentials / "development.toml.enc").unlink()
        result = self.run_dev()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Follow Local development in README.md", result.stderr)
        self.assertFalse((self.root / "invocation.json").exists())

    def test_refuses_production_environment_and_storage(self):
        for overrides in ({"POSTDEPLOY_DEV_ENVIRONMENT": "production"},
                          {"POSTDEPLOY_STORAGE_PREFIX": "production/rust-candidate-v1/"}):
            with self.subTest(overrides=overrides):
                self.assertEqual(self.run_dev(**overrides).returncode, 2)
                self.assertFalse((self.root / "invocation.json").exists())

    def test_preserves_the_application_exit_status(self):
        self.assertEqual(self.run_dev(CARGO_EXIT="17").returncode, 17)


if __name__ == "__main__":
    unittest.main()

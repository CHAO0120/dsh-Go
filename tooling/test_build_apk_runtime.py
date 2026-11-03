"""Run the actual APK entrypoint, stopping before any installed build toolchain."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


TOOLING = Path(__file__).resolve().parent


class BuildApkRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "tooling").mkdir()
        for name in ("build-apk.sh", "build_number.py"):
            shutil.copyfile(TOOLING / name, self.root / "tooling" / name)
        # Real utilities only; no Flutter/Gradle stub and no Android execution.
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "python3").symlink_to(sys.executable)
        (self.bin / "dirname").symlink_to(shutil.which("dirname"))

    def manifest(self, abi, content):
        file = self.root / "runtime/out" / abi / "assets/runtime/manifest.json"
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content, encoding="utf-8")

    def run_build(self, flavor="arm64"):
        return subprocess.run(
            ["/bin/bash", str(self.root / "tooling/build-apk.sh"),
             "--build-name", "1.0.9", "--build-number", "1", "--keep-daemon", "-f", flavor],
            env={**os.environ, "PATH": str(self.bin)}, capture_output=True, text=True,
        )

    def assert_runtime_rejected(self, result, abi):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runtime manifest must have schema 2", result.stderr)
        self.assertIn(abi, result.stderr)
        self.assertIn(f"bash runtime/build-runtime.sh {abi}", result.stderr)
        self.assertNotIn("flutter is not on PATH", result.stderr)
        self.assertFalse((self.root / "app/build").exists())

    def test_old_runtime_is_rejected_before_toolchain(self):
        self.manifest("arm64-v8a", json.dumps({"schema": 1}))
        self.assert_runtime_rejected(self.run_build(), "arm64-v8a")

    def test_missing_or_invalid_manifest_is_rejected(self):
        self.assert_runtime_rejected(self.run_build(), "arm64-v8a")
        for content in ("{", "[]", "{}", '{"schema":"2"}', '{"schema":2.0}', '{"schema":true}'):
            with self.subTest(content=content):
                self.manifest("arm64-v8a", content)
                self.assert_runtime_rejected(self.run_build(), "arm64-v8a")

    def test_all_checks_each_selected_abi(self):
        self.manifest("arm64-v8a", '{"schema":2}')
        self.manifest("x86_64", '{"schema":1}')
        self.assert_runtime_rejected(self.run_build("all"), "x86_64")

    def test_x64_checks_its_packaged_manifest(self):
        self.manifest("arm64-v8a", '{"schema":2}')
        self.manifest("x86_64", '{"schema":1}')
        self.assert_runtime_rejected(self.run_build("x64"), "x86_64")

    def test_schema_two_reaches_real_toolchain_gate(self):
        self.manifest("arm64-v8a", '{"schema":2}')
        self.manifest("x86_64", '{"schema":1}')
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("flutter is not on PATH", result.stderr)
        self.assertNotIn("runtime manifest must have schema 2", result.stderr)
        self.manifest("x86_64", '{"schema":2}')
        result = self.run_build("all")
        self.assertIn("flutter is not on PATH", result.stderr)
        self.assertNotIn("runtime manifest must have schema 2", result.stderr)


if __name__ == "__main__":
    unittest.main()

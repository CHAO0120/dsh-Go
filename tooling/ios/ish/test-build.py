#!/usr/bin/env python3
"""Integrity failure gates; no SDK, downloads or guest execution."""
import importlib.util
import pathlib
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('ish_build', pathlib.Path(__file__).with_name('build.py'))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class IntegrityTests(unittest.TestCase):
    def test_vdso_rejects_dummy_and_wrong_arch(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'vdso'
            for data in (b'', b'not ELF', b'\x7fELF\x02\x01\x01' + b'\0' * 57):
                path.write_bytes(data)
                with self.assertRaises(RuntimeError):
                    build.verify_vdso(path)
            data = bytearray(64)
            data[:7] = b'\x7fELF\x02\x01\x01'
            struct.pack_into('<HHI', data, 16, 3, 183, 1)
            path.write_bytes(data)
            self.assertEqual(build.verify_vdso(path), build.digest(path))

    def test_cached_archive_is_reverified_before_extraction(self):
        with tempfile.TemporaryDirectory() as tmp:
            old = build.CACHE
            build.CACHE = pathlib.Path(tmp)
            try:
                (build.CACHE / (build.LOCK['commit'] + '.tar.gz')).write_bytes(b'corrupted cache')
                with self.assertRaisesRegex(RuntimeError, 'SHA256 mismatch'):
                    build.download()
            finally:
                build.CACHE = old


if __name__ == '__main__':
    unittest.main()

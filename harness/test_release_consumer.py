"""The release gate must use the archive and reject stale or wrong results."""

import pathlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import check_consumer as consumer


class ConsumerGateTests(unittest.TestCase):
    def make_archive(self, directory, **files):
        archive = directory / "package.zip"
        with zipfile.ZipFile(archive, "w") as packed:
            for name, content in files.items():
                packed.writestr(name, content)
        return archive

    def test_version_is_read_from_the_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            archive = self.make_archive(root, **{
                "moon.mod": 'name = "superbigcup325/moonlake"\nversion = "0.4.42"\n',
            })
            self.assertEqual(consumer.unpack_archive(archive, root / "unpacked"), "0.4.42")

    def test_workspace_override_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            archive = self.make_archive(root, **{
                "moon.mod": 'name = "superbigcup325/moonlake"\nversion = "0.4.0"\n',
                "moon.work": 'members = ["../../checkout"]\n',
            })
            with self.assertRaisesRegex(ValueError, "workspace override"):
                consumer.unpack_archive(archive, root / "unpacked")

    def test_zip_cannot_escape_the_package(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            archive = self.make_archive(root, **{"../outside": "not a package file"})
            with self.assertRaisesRegex(ValueError, "escapes its package"):
                consumer.unpack_archive(archive, root / "unpacked")
            self.assertFalse((root / "outside").exists())

    def test_stale_version_fails_even_when_the_query_results_match(self):
        output = "\n".join([
            "version|0.3.1",
            *(f"{name}|{consumer.ROWS}" for name in ("csv", "raw", "snappy")),
            "drop|ok",
        ])
        with self.assertRaisesRegex(ValueError, "consumer output differs"):
            consumer.check_output(output, "0.4.0-dev")

    def test_wrong_value_fails_even_when_the_version_matches(self):
        output = "\n".join([
            "version|0.4.0-dev",
            *(f"{name}|{consumer.ROWS}" for name in ("csv", "raw", "snappy")),
            "drop|ok",
        ]).replace('"total":15', '"total":999', 1)
        with self.assertRaisesRegex(ValueError, "consumer output differs"):
            consumer.check_output(output, "0.4.0-dev")

    def test_fresh_home_does_not_copy_credentials_or_registry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            toolchain = root / "toolchain"
            for name in ("bin", "lib", "include"):
                (toolchain / name).mkdir(parents=True)
            (toolchain / "credentials.json").write_text("private test fixture")
            (toolchain / "registry").mkdir()
            with patch.object(consumer.shutil, "which", return_value=str(toolchain / "bin" / "moon")):
                consumer.fresh_moon_home(root / "fresh")
            self.assertEqual(
                sorted(path.name for path in (root / "fresh").iterdir()),
                ["bin", "include", "lib"],
            )


if __name__ == "__main__":
    unittest.main()

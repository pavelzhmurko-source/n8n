import os
import pathlib
import subprocess
import tempfile
import unittest


N8N_IMAGE = "n8nio/n8n:3.1.0@sha256:6e9f220e9cf0d2f17d3c2371c8d8a6fe6720f99b82a9672afb96bf068cfd04a5"


@unittest.skipUnless(os.environ.get("RUN_DOCKER_TESTS") == "1", "set RUN_DOCKER_TESTS=1")
class BackupVolumeIntegrationTests(unittest.TestCase):
    def test_volume_archive_can_be_staged_and_validated(self):
        suffix = str(os.getpid())
        source = f"coursekit-backup-source-test-{suffix}"
        stage = f"coursekit-backup-stage-test-{suffix}"
        with tempfile.TemporaryDirectory() as directory:
            try:
                run(["docker", "volume", "create", source])
                run(["docker", "volume", "create", stage])
                run([
                    "docker", "run", "--rm", "--user", "0:0", "--entrypoint", "/bin/sh",
                    "-v", f"{source}:/data", N8N_IMAGE,
                    "-c", "printf test-database > /data/database.sqlite",
                ])
                run([
                    "docker", "run", "--rm", "--user", "0:0", "--entrypoint", "/bin/sh",
                    "-v", f"{source}:/source:ro", "-v", f"{directory}:/backup",
                    N8N_IMAGE, "-c", "cd /source && tar -czf /backup/n8n-data.tar.gz .",
                ])
                self.assertTrue((pathlib.Path(directory) / "n8n-data.tar.gz").is_file())
                run([
                    "docker", "run", "--rm", "--user", "0:0", "--entrypoint", "/bin/sh",
                    "-v", f"{stage}:/target", "-v", f"{directory}:/backup:ro",
                    N8N_IMAGE, "-c", "cd /target && tar -xzf /backup/n8n-data.tar.gz",
                ])
                result = run([
                    "docker", "run", "--rm", "--user", "0:0", "--entrypoint", "/bin/sh",
                    "-v", f"{stage}:/data:ro", N8N_IMAGE,
                    "-c", "cat /data/database.sqlite",
                ])
                self.assertEqual(result.stdout, "test-database")
            finally:
                subprocess.run(["docker", "volume", "rm", "-f", source, stage], capture_output=True)


def run(command):
    return subprocess.run(command, text=True, capture_output=True, timeout=180, check=True)


if __name__ == "__main__":
    unittest.main()

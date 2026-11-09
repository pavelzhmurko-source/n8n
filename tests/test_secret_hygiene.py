import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
TELEGRAM_TOKEN = re.compile(r"(?<![A-Za-z0-9_])\d{6,12}:[A-Za-z0-9_-]{30,}")


class SecretHygieneTests(unittest.TestCase):
    def test_non_test_package_files_contain_no_telegram_token(self):
        findings = []
        for path in ROOT.rglob("*"):
            if not path.is_file() or ".git" in path.parts or "tests" in path.parts:
                continue
            if "__pycache__" in path.parts:
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            if TELEGRAM_TOKEN.search(text):
                findings.append(str(path.relative_to(ROOT)))
        self.assertEqual(findings, [], f"possible Telegram token in: {findings}")

    def test_gitignore_covers_runtime_secrets_and_backups(self):
        ignore = (ROOT / ".gitignore").read_text(encoding="utf-8")
        for rule in [".env.*", ".runtime/", "*.secret", "backups/", "*.sqlite"]:
            self.assertIn(rule, ignore)

    def test_no_private_key_blocks(self):
        findings = []
        private_key_marker = "-----BEGIN " + "PRIVATE KEY-----"
        openssh_marker = "-----BEGIN " + "OPENSSH PRIVATE KEY-----"
        for path in ROOT.rglob("*"):
            if not path.is_file() or ".git" in path.parts or "__pycache__" in path.parts:
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            if private_key_marker in text or openssh_marker in text:
                findings.append(str(path.relative_to(ROOT)))
        self.assertEqual(findings, [], f"private key material in: {findings}")


if __name__ == "__main__":
    unittest.main()

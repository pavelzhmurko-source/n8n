import json
import http.client
import os
import pathlib
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[1]
N8N_IMAGE = "n8nio/n8n:3.1.0@sha256:6e9f220e9cf0d2f17d3c2371c8d8a6fe6720f99b82a9672afb96bf068cfd04a5"


@unittest.skipUnless(os.environ.get("RUN_N8N_TESTS") == "1", "set RUN_N8N_TESTS=1")
class N8nBootstrapIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.suffix = str(os.getpid())
        cls.container = f"coursekit-n8n-test-{cls.suffix}"
        cls.volume = f"coursekit-n8n-test-data-{cls.suffix}"
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.addClassCleanup(subprocess.run, ["docker", "volume", "rm", cls.volume], capture_output=True)
        cls.addClassCleanup(subprocess.run, ["docker", "rm", "-f", cls.container], capture_output=True)
        directory = pathlib.Path(cls.temp.name)
        cls.workflow_path = directory / "workflow.json"
        cls.credentials_path = directory / "credentials.json"

        guard = (ROOT / "workflow/guard.js").read_text(encoding="utf-8")
        guard = guard.replace("__ALLOWED_USER_IDS_JSON__", '["42"]')
        workflow = json.loads((ROOT / "workflow/telegram-echo.template.json").read_text(encoding="utf-8"))
        workflow[0]["nodes"][1]["parameters"]["jsCode"] = guard
        cls.workflow_path.write_text(json.dumps(workflow, ensure_ascii=False), encoding="utf-8")
        credential = [
            {
                "id": "telegram-course-bot",
                "name": "Telegram Course Bot",
                "type": "telegramApi",
                "data": {"accessToken": "123456789:" + ("A" * 35)},
            }
        ]
        cls.credentials_path.write_text(json.dumps(credential), encoding="utf-8")

        run(["docker", "volume", "create", cls.volume], timeout=30)
        run(
            [
                "docker", "run", "-d", "--name", cls.container,
                "-p", "127.0.0.1::5678", "-v", f"{cls.volume}:/home/node/.n8n",
                "-e", "N8N_ENCRYPTION_KEY=coursekit-integration-test-key-0000000000000000",
                "-e", "N8N_DIAGNOSTICS_ENABLED=false",
                "-e", "N8N_VERSION_NOTIFICATIONS_ENABLED=false",
                "-e", "N8N_TEMPLATES_ENABLED=false",
                N8N_IMAGE,
            ],
            timeout=180,
            capture=False,
        )
        mapping = run(["docker", "port", cls.container, "5678/tcp"], timeout=30).stdout.strip()
        cls.port = int(mapping.rsplit(":", 1)[1])
        wait_for_readiness(cls.port, timeout=300)
        status, _ = request_json(
            cls.port,
            "/rest/owner/setup",
            method="POST",
            payload={
                "email": "coursekit-integration@example.invalid",
                "firstName": "Course",
                "lastName": "Kit",
                "password": "IntegrationPassword123!",
            },
        )
        if status != 200:
            raise AssertionError(f"owner setup failed with HTTP {status}")
        run(["docker", "stop", cls.container], timeout=60, capture=False)

        common = [
            "docker", "run", "--rm",
            "-e", "N8N_ENCRYPTION_KEY=coursekit-integration-test-key-0000000000000000",
            "-e", "N8N_DIAGNOSTICS_ENABLED=false",
            "-e", "N8N_VERSION_NOTIFICATIONS_ENABLED=false",
            "-e", "N8N_TEMPLATES_ENABLED=false",
            "-v", f"{cls.volume}:/home/node/.n8n",
        ]
        run(
            common + ["-v", f"{cls.credentials_path}:/tmp/credentials.json:ro", N8N_IMAGE,
                      "import:credentials", "--input=/tmp/credentials.json"],
            timeout=420,
        )
        run(
            common + ["-v", f"{cls.workflow_path}:/tmp/workflow.json:ro", N8N_IMAGE,
                      "import:workflow", "--input=/tmp/workflow.json"],
            timeout=420,
        )
        export_directory = directory / "export"
        export_directory.mkdir()
        run(
            common + ["-v", f"{export_directory}:/tmp/export", N8N_IMAGE,
                      "export:workflow", "--all", "--output=/tmp/export/workflows.json"],
            timeout=420,
        )
        exported = json.loads((export_directory / "workflows.json").read_text(encoding="utf-8"))
        if not any(item.get("id") == "telegramCourseMvp" for item in exported):
            raise AssertionError("exported workflow was not found")
        published = run(common + [N8N_IMAGE, "publish:workflow", "--id=telegramCourseMvp"], timeout=420)
        cls.publish_output = (published.stdout or "") + (published.stderr or "")
        run(["docker", "start", cls.container], timeout=60, capture=False)
        mapping = run(["docker", "port", cls.container, "5678/tcp"], timeout=30).stdout.strip()
        cls.port = int(mapping.rsplit(":", 1)[1])
        wait_for_readiness(cls.port, timeout=300)
        wait_for_webhook(cls.port, timeout=300)

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["docker", "rm", "-f", cls.container], capture_output=True)
        subprocess.run(["docker", "volume", "rm", cls.volume], capture_output=True)
        cls.temp.cleanup()

    def test_imported_workflow_is_published_and_reachable(self):
        status, body = request_json(
            self.port,
            "/webhook/telegram-course",
            method="POST",
            payload={
                "update_id": 1,
                "message": {
                    "chat": {"id": 999, "type": "private"},
                    "from": {"id": 999},
                    "text": "denied user must not call Telegram",
                },
            },
        )
        if status != 200:
            logged = run(["docker", "logs", self.container], timeout=30)
            logs = (logged.stdout or "") + (logged.stderr or "")
            self.fail(f"HTTP {status}: {body}\npublish output:\n{self.publish_output}\nn8n logs:\n{logs[-6000:]}")
        self.assertIn("Workflow was started", body)

    def test_instance_reports_owner_setup_complete(self):
        status, body = request_json(self.port, "/rest/settings")
        self.assertEqual(status, 200)
        self.assertFalse(json.loads(body)["data"]["userManagement"]["showSetupOnFirstLoad"])


def run(command, timeout, capture=True):
    result = subprocess.run(
        command,
        text=True,
        capture_output=capture,
        stdout=None if capture else subprocess.DEVNULL,
        stderr=None if capture else subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if result.returncode != 0:
        detail = ((result.stderr or "") + "\n" + (result.stdout or ""))[-3000:]
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(command[:4])}\n{detail}")
    return result


def wait_for_readiness(port, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
            connection.request("GET", "/healthz/readiness")
            response = connection.getresponse()
            response.read()
            connection.close()
            if response.status == 200:
                return
        except OSError:
            time.sleep(1)
    raise TimeoutError("n8n readiness timed out")


def request_json(port, path, method="GET", payload=None):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
    connection.request(method, path, body=data, headers={"Content-Type": "application/json"})
    response = connection.getresponse()
    body = response.read().decode("utf-8")
    connection.close()
    return response.status, body


def wait_for_webhook(port, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        status, _ = request_json(
            port,
            "/webhook/telegram-course",
            method="POST",
            payload={
                "update_id": 2147483000,
                "message": {
                    "chat": {"id": 0, "type": "private"},
                    "from": {"id": 0},
                    "text": "readiness-probe",
                },
            },
        )
        if status == 200:
            return
        time.sleep(1)
    raise TimeoutError("n8n production webhook registration timed out")


if __name__ == "__main__":
    unittest.main()

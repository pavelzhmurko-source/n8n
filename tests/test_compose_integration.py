import http.client
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get("RUN_COMPOSE_TESTS") == "1", "set RUN_COMPOSE_TESTS=1")
class ComposeStackIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = f"coursekit-compose-test-{os.getpid()}"
        cls.temp = tempfile.TemporaryDirectory()
        directory = pathlib.Path(cls.temp.name)
        cls.port = free_port()
        secret = "compose_test_webhook_secret"
        template = (ROOT / "config/nginx/coursekit.conf.template").read_text(encoding="utf-8")
        (directory / "coursekit.conf").write_text(
            template.replace("__WEBHOOK_SECRET__", secret), encoding="utf-8"
        )
        (directory / "n8n_encryption_key").write_text("compose-test-encryption-key-0000000000000000", encoding="utf-8")
        (directory / "runner_auth_token").write_text("compose-test-runner-token-000000000000000", encoding="utf-8")
        (directory / "import").mkdir()
        cls.env = os.environ.copy()
        cls.env.update(
            {
                "COURSEKIT_N8N_PORT": str(cls.port),
                "COURSEKIT_WEBHOOK_URL": f"http://127.0.0.1:{cls.port}/",
                "COURSEKIT_NGINX_CONFIG": str(directory / "coursekit.conf"),
                "COURSEKIT_ENCRYPTION_KEY_FILE": str(directory / "n8n_encryption_key"),
                "COURSEKIT_RUNNER_TOKEN_FILE": str(directory / "runner_auth_token"),
                "COURSEKIT_IMPORT_DIR": str(directory / "import"),
            }
        )
        cls.addClassCleanup(cls.temp.cleanup)
        cls.addClassCleanup(
            subprocess.run,
            compose_command(cls.project, "down", "-v", "--remove-orphans"),
            cwd=ROOT, env=cls.env, text=True, capture_output=True, timeout=180,
        )
        compose(cls.project, cls.env, "up", "-d", "n8n", "task-runners", "proxy", timeout=480)
        wait_http(cls.port, "/healthz/readiness", timeout=300)
        wait_for_runner(cls.project, cls.env, timeout=180)

    @classmethod
    def tearDownClass(cls):
        subprocess.run(
            compose_command(cls.project, "down", "-v", "--remove-orphans"),
            cwd=ROOT, env=cls.env, text=True, capture_output=True, timeout=180,
        )
        cls.temp.cleanup()

    def test_stack_is_healthy_and_runner_uses_secret_file(self):
        container_id = compose(self.project, self.env, "ps", "-q", "n8n").stdout.strip()
        inspect = subprocess.run(
            ["docker", "inspect", container_id], text=True, capture_output=True, timeout=30, check=True
        )
        data = json.loads(inspect.stdout)[0]
        self.assertEqual(data["State"]["Health"]["Status"], "healthy")
        environment = data["Config"]["Env"]
        self.assertIn("N8N_RUNNERS_AUTH_TOKEN_FILE=/run/secrets/runner_auth_token", environment)
        self.assertNotIn("compose-test-runner-token-000000000000000", "\n".join(environment))

    def test_proxy_is_not_published_to_windows(self):
        proxy_id = compose(self.project, self.env, "ps", "-q", "proxy").stdout.strip()
        inspect = subprocess.run(
            ["docker", "port", proxy_id], text=True, capture_output=True, timeout=30, check=True
        )
        self.assertEqual(inspect.stdout.strip(), "")


def compose_command(project, *arguments):
    return ["docker", "compose", "--project-name", project, "-f", str(ROOT / "compose.yaml"), *arguments]


def compose(project, env, *arguments, timeout=120):
    result = subprocess.run(
        compose_command(project, *arguments), cwd=ROOT, env=env, text=True,
        capture_output=True, timeout=timeout, check=False,
    )
    if result.returncode != 0:
        raise RuntimeError((result.stderr + "\n" + result.stdout)[-4000:])
    return result


def free_port():
    with socket.socket() as handle:
        handle.bind(("127.0.0.1", 0))
        return handle.getsockname()[1]


def wait_http(port, path, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
            connection.request("GET", path)
            response = connection.getresponse()
            response.read()
            connection.close()
            if response.status == 200:
                return
        except OSError:
            pass
        time.sleep(1)
    raise TimeoutError("Compose n8n readiness timed out")


def wait_for_runner(project, env, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        logs = compose(project, env, "logs", "--no-color", "--tail", "200", "n8n")
        if "Registered runner" in logs.stdout + logs.stderr:
            return
        time.sleep(1)
    raise TimeoutError("external task runner did not register")


if __name__ == "__main__":
    unittest.main()

import os
import pathlib
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request
import re


ROOT = pathlib.Path(__file__).resolve().parents[1]
NGINX_IMAGE = "nginx:1.30.6-alpine@sha256:583b7f2fce1cdb8da5ad5c39ebd3c33b98b87d493190e548bdee1fa8c619c311"
CLOUDFLARED_IMAGE = "cloudflare/cloudflared:2026.10.7@sha256:4955524aeaa379e154023d5a027c250f7b35041a2e7e950cf13f144bc9b9c5ba"


@unittest.skipUnless(os.environ.get("RUN_DOCKER_TESTS") == "1", "set RUN_DOCKER_TESTS=1")
class ProxyIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.suffix = str(os.getpid())
        cls.network = f"coursekit-proxy-test-{cls.suffix}"
        cls.upstream = f"coursekit-upstream-{cls.suffix}"
        cls.proxy = f"coursekit-proxy-{cls.suffix}"
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.addClassCleanup(subprocess.run, ["docker", "network", "rm", cls.network], capture_output=True)
        cls.addClassCleanup(
            subprocess.run, ["docker", "rm", "-f", cls.proxy, cls.upstream], capture_output=True
        )
        directory = pathlib.Path(cls.temp.name)
        upstream_conf = directory / "upstream.conf"
        proxy_conf = directory / "proxy.conf"
        upstream_conf.write_text(
            "server { listen 5678; location = /webhook/telegram-course { return 204; } location / { return 418; } }\n",
            encoding="utf-8",
        )
        template = (ROOT / "config/nginx/coursekit.conf.template").read_text(encoding="utf-8")
        proxy_conf.write_text(template.replace("__WEBHOOK_SECRET__", "test_secret_123"), encoding="utf-8")

        run(["docker", "network", "create", cls.network])
        run(
            [
                "docker", "run", "-d", "--name", cls.upstream, "--network", cls.network,
                "--network-alias", "n8n", "-v", f"{upstream_conf}:/etc/nginx/conf.d/default.conf:ro",
                NGINX_IMAGE,
            ]
        )
        run(
            [
                "docker", "run", "-d", "--name", cls.proxy, "--network", cls.network,
                "-p", "127.0.0.1::8080", "-v", f"{proxy_conf}:/etc/nginx/conf.d/default.conf:ro",
                NGINX_IMAGE,
            ]
        )
        mapping = run(["docker", "port", cls.proxy, "8080/tcp"]).stdout.strip()
        cls.port = int(mapping.rsplit(":", 1)[1])
        wait_for_port(cls.port)

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["docker", "rm", "-f", cls.proxy, cls.upstream], capture_output=True)
        subprocess.run(["docker", "network", "rm", cls.network], capture_output=True)
        cls.temp.cleanup()

    def request(self, path, method="POST", secret=None, body=b"{}"):
        headers = {"Content-Type": "application/json"}
        if secret:
            headers["X-Telegram-Bot-Api-Secret-Token"] = secret
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}", data=body if method == "POST" else None,
            headers=headers, method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status
        except urllib.error.HTTPError as error:
            return error.code

    def test_only_exact_post_with_secret_reaches_upstream(self):
        self.assertEqual(self.request("/webhook/telegram-course", secret="test_secret_123"), 204)
        self.assertEqual(self.request("/webhook/telegram-course", secret="wrong"), 403)
        self.assertEqual(self.request("/webhook/telegram-course", method="GET", secret="test_secret_123"), 403)
        self.assertEqual(self.request("/rest/settings", secret="test_secret_123"), 404)
        self.assertEqual(self.request("/webhook-test/telegram-course", secret="test_secret_123"), 404)

    def test_body_limit_is_enforced(self):
        status = self.request(
            "/webhook/telegram-course", secret="test_secret_123", body=b"x" * (1024 * 1024 + 1)
        )
        self.assertEqual(status, 413)


@unittest.skipUnless(os.environ.get("RUN_TUNNEL_TESTS") == "1", "set RUN_TUNNEL_TESTS=1")
class PublicTunnelIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.suffix = str(os.getpid())
        cls.network = f"coursekit-tunnel-test-{cls.suffix}"
        cls.upstream = f"coursekit-tunnel-upstream-{cls.suffix}"
        cls.proxy = f"coursekit-tunnel-proxy-{cls.suffix}"
        cls.tunnel = f"coursekit-tunnel-client-{cls.suffix}"
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.addClassCleanup(subprocess.run, ["docker", "network", "rm", cls.network], capture_output=True)
        cls.addClassCleanup(
            subprocess.run,
            ["docker", "rm", "-f", cls.tunnel, cls.proxy, cls.upstream],
            capture_output=True,
        )
        directory = pathlib.Path(cls.temp.name)
        upstream_conf = directory / "upstream.conf"
        proxy_conf = directory / "proxy.conf"
        upstream_conf.write_text(
            "server { listen 5678; location = /webhook/telegram-course { return 204; } location / { return 418; } }\n",
            encoding="utf-8",
        )
        template = (ROOT / "config/nginx/coursekit.conf.template").read_text(encoding="utf-8")
        proxy_conf.write_text(template.replace("__WEBHOOK_SECRET__", "tunnel_test_secret"), encoding="utf-8")

        run(["docker", "network", "create", cls.network])
        run([
            "docker", "run", "-d", "--name", cls.upstream, "--network", cls.network,
            "--network-alias", "n8n", "-v", f"{upstream_conf}:/etc/nginx/conf.d/default.conf:ro",
            NGINX_IMAGE,
        ])
        run([
            "docker", "run", "-d", "--name", cls.proxy, "--network", cls.network,
            "--network-alias", "proxy", "-v", f"{proxy_conf}:/etc/nginx/conf.d/default.conf:ro",
            NGINX_IMAGE,
        ])
        run([
            "docker", "run", "-d", "--restart", "on-failure:3", "--name", cls.tunnel, "--network", cls.network,
            CLOUDFLARED_IMAGE, "tunnel", "--no-autoupdate", "--protocol", "http2",
            "--url", "http://proxy:8080",
        ])
        cls.public_url = wait_for_tunnel_url(cls.tunnel, timeout=180)

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["docker", "rm", "-f", cls.tunnel, cls.proxy, cls.upstream], capture_output=True)
        subprocess.run(["docker", "network", "rm", cls.network], capture_output=True)
        cls.temp.cleanup()

    def public_request(self, path, method="GET", secret=None):
        headers = {"Content-Type": "application/json"}
        if secret:
            headers["X-Telegram-Bot-Api-Secret-Token"] = secret
        request = urllib.request.Request(
            self.public_url + path,
            data=b"{}" if method == "POST" else None,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status
        except urllib.error.HTTPError as error:
            return error.code

    def test_public_tunnel_exposes_only_protected_webhook(self):
        try:
            valid_status = self.public_request("/webhook/telegram-course", "POST", "tunnel_test_secret")
        except urllib.error.URLError as error:
            if "403 Forbidden" in str(error):
                self.skipTest("the current environment blocks outbound requests to the generated trycloudflare.com host")
            raise
        self.assertEqual(valid_status, 204)
        self.assertEqual(self.public_request("/webhook/telegram-course", "POST", "wrong"), 403)
        self.assertEqual(self.public_request("/rest/settings"), 404)


def run(command):
    return subprocess.run(command, text=True, capture_output=True, timeout=60, check=True)


def wait_for_port(port):
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return
        except OSError:
            time.sleep(0.25)
    raise TimeoutError(f"proxy port {port} did not open")


def wait_for_tunnel_url(container, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = subprocess.run(
            ["docker", "logs", container], text=True, capture_output=True, timeout=15, check=False
        )
        match = re.search(r"https://[a-z0-9-]+\.trycloudflare\.com", result.stdout + result.stderr)
        if match:
            return match.group(0)
        status = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Status}}", container],
            text=True, capture_output=True, timeout=15, check=False,
        ).stdout.strip()
        if status not in {"running", "restarting"}:
            detail = (result.stdout + result.stderr)[-2000:]
            raise RuntimeError("cloudflared stopped before publishing a URL: " + detail)
        time.sleep(1)
    raise TimeoutError("cloudflared did not publish a Quick Tunnel URL")


if __name__ == "__main__":
    unittest.main()

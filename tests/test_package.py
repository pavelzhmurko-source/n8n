import json
import os
import pathlib
import re
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class PackageContractTests(unittest.TestCase):
    def test_required_files_exist(self):
        required = [
            "compose.yaml",
            "launcher.ps1",
            "start.cmd",
            "scripts/CourseKit.psm1",
            "scripts/backup.ps1",
            "scripts/restore.ps1",
            "backup.cmd",
            "restore.cmd",
            "config/nginx/coursekit.conf.template",
            "workflow/guard.js",
            "workflow/telegram-echo.template.json",
            "README.md",
            "INFRASTRUCTURE.md",
            "IMPLEMENTATION_CHECKLIST.md",
            "RESEARCH.md",
            "WINDOWS_ACCEPTANCE.md",
            "VALIDATION.md",
            "CLOUD_ENVIRONMENT.md",
        ]
        missing = [name for name in required if not (ROOT / name).is_file()]
        self.assertEqual(missing, [], f"Missing package files: {missing}")

    def test_windows_powershell_files_have_utf8_bom(self):
        scripts = [
            ROOT / "launcher.ps1",
            ROOT / "scripts/CourseKit.psm1",
            ROOT / "scripts/backup.ps1",
            ROOT / "scripts/restore.ps1",
            ROOT / "tests/run-tests.ps1",
        ]
        missing_bom = [
            str(path.relative_to(ROOT))
            for path in scripts
            if not path.read_bytes().startswith(b"\xef\xbb\xbf")
        ]
        self.assertEqual(
            missing_bom,
            [],
            f"Windows PowerShell 5.1 requires UTF-8 BOM: {missing_bom}",
        )

    def test_images_are_version_and_digest_pinned(self):
        compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        images = re.findall(r"^\s*image:\s*(\S+)\s*$", compose, re.MULTILINE)
        self.assertEqual(len(images), 4)
        for image in images:
            self.assertRegex(image, r":[^@\s]+@sha256:[0-9a-f]{64}$")
            self.assertNotIn(":latest", image)

    def test_internal_runner_token_uses_mounted_files(self):
        compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        self.assertIn("N8N_RUNNERS_AUTH_TOKEN_FILE: /run/secrets/runner_auth_token", compose)
        self.assertNotIn("COURSEKIT_RUNNER_AUTH_TOKEN", compose)

    def test_editor_port_is_loopback_only(self):
        compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        self.assertIn('"127.0.0.1:${COURSEKIT_N8N_PORT:-5678}:5678"', compose)
        self.assertNotRegex(compose, r"(?m)^\s*-\s*[\"']?5678:5678")

    def test_proxy_has_one_public_route_and_secret_check(self):
        config = (ROOT / "config/nginx/coursekit.conf.template").read_text(encoding="utf-8")
        self.assertIn("location = /webhook/telegram-course", config)
        self.assertIn("__WEBHOOK_SECRET__", config)
        self.assertIn("limit_except POST", config)
        self.assertRegex(config, r"location /\s*\{\s*return 404;")
        self.assertNotIn("/healthz", config)

    def test_workflow_template_contains_no_secret(self):
        workflow = json.loads(
            (ROOT / "workflow/telegram-echo.template.json").read_text(encoding="utf-8")
        )
        serialized = json.dumps(workflow)
        self.assertNotRegex(serialized, r"\d{6,}:[A-Za-z0-9_-]{20,}")
        self.assertIn("telegram-course-bot", serialized)
        self.assertIn("__GUARD_CODE__", serialized)
        telegram_node = next(node for node in workflow[0]["nodes"] if node["type"] == "n8n-nodes-base.telegram")
        self.assertTrue(telegram_node["retryOnFail"])
        self.assertEqual(telegram_node["maxTries"], 3)

    def test_windows_generator_preserves_workflow_json_shape(self):
        module = (ROOT / "scripts/CourseKit.psm1").read_text(encoding="utf-8")
        self.assertIn("$workflowJson.Replace($guardPlaceholder, $guardJson)", module)
        self.assertIn("Write-Utf8File -Path $paths.Workflow -Content $workflowJson", module)
        self.assertNotIn("ConvertTo-Json -InputObject $workflows", module)

    def test_launcher_preserves_existing_workflow_and_has_backup_restore(self):
        module = (ROOT / "scripts/CourseKit.psm1").read_text(encoding="utf-8")
        self.assertIn("export:workflow', '--all'", module)
        self.assertIn("No workflows found with specified filters", module)
        self.assertIn("У новій базі n8n ще немає workflow", module)
        self.assertIn("Наявний workflow збережено без перезапису", module)
        self.assertIn("function Backup-CourseKit", module)
        self.assertIn("function Restore-CourseKitBackup", module)
        self.assertIn("Windows DPAPI CurrentUser", module)
        self.assertIn("$matches[$matches.Count - 1].Value", module)

    def test_process_exit_code_uses_dotnet_process_on_windows_powershell(self):
        module = (ROOT / "scripts/CourseKit.psm1").read_text(encoding="utf-8")
        self.assertIn("New-Object System.Diagnostics.ProcessStartInfo", module)
        self.assertIn("$process.StandardOutput.ReadToEndAsync()", module)
        self.assertIn("$process.StandardError.ReadToEndAsync()", module)
        self.assertIn("$exitCode = [int]$process.ExitCode", module)
        self.assertNotIn("Start-Process -FilePath $FilePath", module)

    def test_first_compose_start_allows_slow_image_download(self):
        module = (ROOT / "scripts/CourseKit.psm1").read_text(encoding="utf-8")
        self.assertIn(
            "@('up', '-d', 'n8n', 'task-runners', 'proxy') -TimeoutSeconds 1800",
            module,
        )
        self.assertIn("Останній вивід", module)

    def test_runtime_is_recreated_after_stale_windows_mounts(self):
        module = (ROOT / "scripts/CourseKit.psm1").read_text(encoding="utf-8")
        self.assertIn("$security.SetOwner($identity)", module)
        self.assertIn("Remove-Item -LiteralPath $paths.Runtime -Recurse -Force", module)
        remove_containers = module.index("$previousContainers = @(Get-CourseProjectContainerIds)")
        create_runtime = module.index("New-CourseRuntimeFiles -Configuration $configuration", remove_containers)
        self.assertLess(remove_containers, create_runtime)

    def test_container_id_results_are_always_treated_as_arrays(self):
        module = (ROOT / "scripts/CourseKit.psm1").read_text(encoding="utf-8")
        assignments = re.findall(
            r"\$(previousContainers|containers|running|allContainers)\s*=\s*([^\r\n]*Get-CourseProjectContainerIds[^\r\n]*)",
            module,
        )
        self.assertGreaterEqual(len(assignments), 4)
        for name, expression in assignments:
            self.assertTrue(
                expression.strip().startswith("@(Get-CourseProjectContainerIds"),
                f"${name} may become a scalar when exactly one container exists",
            )

    def test_compose_configuration_resolves(self):
        if not shutil_which("docker"):
            self.skipTest("Docker is not installed")
        with tempfile.TemporaryDirectory() as directory:
            runtime = pathlib.Path(directory)
            nginx = runtime / "coursekit.conf"
            key = runtime / "n8n_encryption_key"
            nginx.write_text("events {}\n", encoding="utf-8")
            key.write_text("test-key\n", encoding="utf-8")
            env = os.environ.copy()
            env.update(
                {
                    "COURSEKIT_NGINX_CONFIG": str(nginx),
                    "COURSEKIT_ENCRYPTION_KEY_FILE": str(key),
                    "COURSEKIT_RUNNER_TOKEN_FILE": str(key),
                    "COURSEKIT_IMPORT_DIR": str(runtime),
                    "COURSEKIT_N8N_PORT": "5678",
                    "COURSEKIT_WEBHOOK_URL": "https://example.invalid/",
                }
            )
            result = subprocess.run(
                ["docker", "compose", "-f", str(ROOT / "compose.yaml"), "config", "--quiet"],
                env=env,
                text=True,
                capture_output=True,
                timeout=30,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)


class GuardCodeTests(unittest.TestCase):
    def test_guard_accepts_allowed_text_and_deduplicates(self):
        if not shutil_which("node"):
            self.skipTest("Node.js is not installed")
        guard = (ROOT / "workflow/guard.js").read_text(encoding="utf-8")
        guard = guard.replace("__ALLOWED_USER_IDS_JSON__", '["42"]')
        harness = f"""
const state = {{}};
const execute = ($json) => {{
  const $getWorkflowStaticData = () => state;
  return (() => {{ {guard} }})();
}};
const event = {{body: {{update_id: 7, message: {{chat: {{id: 42, type: 'private'}}, from: {{id: 42}}, text: '  Привіт   курс  '}}}}}};
const first = execute(event);
const second = execute(event);
process.stdout.write(JSON.stringify({{first, second, state}}));
"""
        result = subprocess.run(
            ["node", "-e", harness],
            text=True,
            capture_output=True,
            timeout=20,
            check=True,
        )
        output = json.loads(result.stdout)
        self.assertEqual(output["first"][0]["json"]["chatId"], "42")
        self.assertEqual(output["first"][0]["json"]["replyText"], "Отримано: Привіт курс")
        self.assertEqual(output["second"], [])
        self.assertEqual(output["state"]["processedUpdateIds"], ["7"])

    def test_guard_rejects_untrusted_or_unsupported_updates(self):
        if not shutil_which("node"):
            self.skipTest("Node.js is not installed")
        guard = (ROOT / "workflow/guard.js").read_text(encoding="utf-8")
        guard = guard.replace("__ALLOWED_USER_IDS_JSON__", '["42"]')
        harness = f"""
const state = {{}};
const execute = ($json) => {{
  const $getWorkflowStaticData = () => state;
  return (() => {{ {guard} }})();
}};
const denied = execute({{body: {{update_id: 1, message: {{chat: {{id: 9, type: 'private'}}, from: {{id: 9}}, text: 'x'}}}}}});
const group = execute({{body: {{update_id: 2, message: {{chat: {{id: -1, type: 'group'}}, from: {{id: 42}}, text: 'x'}}}}}});
const photo = execute({{body: {{update_id: 3, message: {{chat: {{id: 42, type: 'private'}}, from: {{id: 42}}, photo: []}}}}}});
process.stdout.write(JSON.stringify({{denied, group, photo}}));
"""
        result = subprocess.run(
            ["node", "-e", harness], text=True, capture_output=True, timeout=20, check=True
        )
        output = json.loads(result.stdout)
        self.assertEqual(output, {"denied": [], "group": [], "photo": []})


def shutil_which(command):
    from shutil import which

    return which(command)


if __name__ == "__main__":
    unittest.main()

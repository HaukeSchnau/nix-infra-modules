"""Exercise the same supplied bindings through both executable runtimes."""

import json
import os
import pathlib
import subprocess
import tempfile
import unittest

import jsonschema


class BindingRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.context = self.root / "context.json"
        self.secrets = self.root / "secrets"
        self.secrets.mkdir()
        (self.secrets / "session").write_text("fixture-token\n")
        self.descriptor = json.loads(
            pathlib.Path(os.environ["BINDING_DESCRIPTOR"]).read_text()
        )
        self.schema = json.loads(pathlib.Path(os.environ["RUNTIME_SCHEMA"]).read_text())
        self.manifest = {
            "schemaVersion": 3,
            "instanceId": "stable-instance-id",
            "project": "requirements-fixture",
            "realization": "development",
            "paths": {
                name: str(self.root / name)
                for name in ("state", "runtime", "cache", "checkout")
            },
            "parameters": {"optional": None},
            "secrets": {"session": "session"},
            "bindings": {
                "database": {
                    "kind": "postgresql",
                    "majorVersion": 17,
                    "host": "127.0.0.1",
                    "port": 5432,
                    "database": "app",
                    "user": "app",
                    "url": "postgresql://app@127.0.0.1:5432/app",
                },
                "uploads": {
                    "kind": "directory",
                    "path": str(self.root / "uploads"),
                    "persistent": True,
                },
                "session": {"kind": "secret", "credential": "session"},
            },
            "endpoints": {
                "web": {
                    "protocol": "http",
                    "listen": {"host": "127.0.0.1", "port": 3000},
                    "url": "https://preview.example",
                }
            },
        }

    def run_runtime(self, realization, *arguments):
        self.manifest["realization"] = realization
        self.context.write_text(json.dumps(self.manifest))
        environment = {
            **os.environ,
            "PROJECT_RUNTIME_FILE": str(self.context),
            "PROJECT_SECRETS_DIR": str(self.secrets),
            "OPTIONAL": "must-not-inherit",
        }
        executable = os.environ[
            "DEVELOPMENT_RUNTIME" if realization == "development" else "RELEASE_RUNTIME"
        ]
        return subprocess.run(
            [executable, *arguments], env=environment, text=True, capture_output=True
        )

    def test_schema_and_environment_agree_across_runtimes(self):
        jsonschema.validate(
            self.descriptor,
            json.loads(pathlib.Path(os.environ["DESCRIPTOR_SCHEMA"]).read_text()),
        )
        for realization in ("development", "release"):
            with self.subTest(realization=realization):
                self.manifest["realization"] = realization
                jsonschema.validate(self.manifest, self.schema)
                result = self.run_runtime(realization, "web")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    result.stdout.splitlines(),
                    [
                        self.manifest["bindings"]["database"]["url"],
                        str(self.root / "uploads"),
                        "fixture-token",
                        "stable-instance-id",
                        "quotes ' and $literal `text`",
                        "next line",
                        "3000",
                        "",
                    ],
                )
                snapshot = self.run_runtime(realization, "context", "snapshot")
                self.assertEqual(snapshot.returncode, 0, snapshot.stderr)
                self.assertEqual(
                    json.loads(snapshot.stdout)["instanceId"], "stable-instance-id"
                )
                self.assertNotIn("fixture-token", snapshot.stdout)
                query = self.run_runtime(
                    realization, "context", "binding", "database", "url"
                )
                self.assertEqual(
                    query.stdout.strip(), self.manifest["bindings"]["database"]["url"]
                )

    def test_each_accepted_postgres_major_runs(self):
        for version in (16, 17):
            self.manifest["bindings"]["database"]["majorVersion"] = version
            for realization in ("development", "release"):
                with self.subTest(version=version, realization=realization):
                    result = self.run_runtime(realization, "web")
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_incompatible_or_missing_binding_prevents_execution(self):
        for kind in ("missing", "wrong-version", "unsafe-credential", "unknown-field"):
            with self.subTest(problem=kind):
                original = json.loads(json.dumps(self.manifest))
                if kind == "missing":
                    self.manifest["bindings"].pop("database")
                elif kind == "wrong-version":
                    self.manifest["bindings"]["database"]["majorVersion"] = 15
                elif kind == "unsafe-credential":
                    self.manifest["secrets"]["session"] = ".."
                else:
                    self.manifest["bindings"]["database"]["unexpected"] = True
                for realization in ("development", "release"):
                    result = self.run_runtime(realization, "web")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")
                self.manifest = original

    def test_missing_credential_file_fails_when_consumed(self):
        (self.secrets / "session").unlink()
        for realization in ("development", "release"):
            snapshot = self.run_runtime(realization, "context", "snapshot")
            self.assertEqual(snapshot.returncode, 0, snapshot.stderr)
            result = self.run_runtime(realization, "web")
            self.assertEqual(result.returncode, 66, result.stderr)
            self.assertEqual(result.stdout, "")

    def test_release_compatibility_rejects_incomplete_and_incompatible_resources(self):
        candidate = self.root / "candidate.json"
        candidate.write_text(json.dumps(self.descriptor))
        policy = {
            "descriptor": self.descriptor,
            "managedJobs": [],
            "bindings": {
                "parameters": {},
                "secrets": ["session"],
                "resources": self.manifest["bindings"],
            },
        }
        host = self.root / "host.json"

        def compatible():
            host.write_text(json.dumps(policy))
            result = subprocess.run(
                [
                    os.environ["JQ"],
                    "-n",
                    "--slurpfile",
                    "host",
                    str(host),
                    "--slurpfile",
                    "candidate",
                    str(candidate),
                    "-f",
                    os.environ["RELEASE_COMPATIBILITY"],
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            return json.loads(result.stdout)

        self.assertTrue(compatible()["compatible"])
        original = json.loads(json.dumps(policy["bindings"]["resources"]))
        for change in (
            lambda resources: resources["database"].pop("url"),
            lambda resources: resources["database"].update(majorVersion=15),
            lambda resources: resources["uploads"].update(path="relative"),
            lambda resources: resources["session"].update(credential="unbound"),
            lambda resources: resources.pop("database"),
        ):
            with self.subTest(change=change):
                policy["bindings"]["resources"] = json.loads(json.dumps(original))
                change(policy["bindings"]["resources"])
                result = compatible()
                self.assertFalse(result["compatible"])
                self.assertTrue(result["reasons"])


if __name__ == "__main__":
    unittest.main()

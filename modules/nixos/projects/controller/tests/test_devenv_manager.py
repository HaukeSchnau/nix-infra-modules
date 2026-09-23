from __future__ import annotations

import json
import pathlib
import tempfile
import unittest
from unittest import mock

from project_controller import devenv_manager
from project_controller.devenv_manager import Graph, activation_script, with_command_barriers

TASKS = [
    {"name": "app:install", "before": ["devenv:enterShell"]},
    {"name": "devenv:enterShell"},
    {"name": "devenv:processes:database", "type": "process", "after": ["app:install"]},
    {"name": "app:migrate", "after": ["devenv:processes:database@ready"]},
    {"name": "devenv:processes:web", "type": "process", "after": ["app:migrate"]},
    {"name": "devenv:processes:mobile", "type": "process", "after": ["devenv:processes:database"]},
    {"name": "app:console", "after": ["app:migrate"]},
    {"name": "app:seed", "before": ["app:console@completed"]},
]


class GraphTest(unittest.TestCase):
    def test_closure_follows_after_and_before_edges_dependencies_first(self):
        graph = Graph(TASKS)
        self.assertEqual(graph.process_closure(["devenv:processes:web"]), ["database", "web"])
        self.assertEqual(
            graph.process_closure(["devenv:processes:web", "devenv:processes:mobile"]), ["database", "web", "mobile"]
        )

    def test_command_barrier_waits_for_the_command_and_its_before_predecessors(self):
        tasks = with_command_barriers(TASKS, {"console": "app:console"}, pathlib.Path("/run/x"), "/capture")
        capture = next(task for task in tasks if task["name"] == "project:command-environment-console")
        self.assertEqual(capture["after"], ["app:migrate", "app:seed@completed"])
        self.assertEqual(capture["env"], {"PROJECT_COMMAND_ENVIRONMENT": "/run/x/command-console.json"})
        graph = Graph(tasks)
        self.assertEqual(graph.process_closure(["devenv:processes:project-command-console"]), ["database", "project-command-console"])


class DemandTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.runtime = pathlib.Path(temp.name)
        (self.runtime / "native.sock").touch()
        self.prepared = devenv_manager.Prepared.__new__(devenv_manager.Prepared)
        self.prepared.runtime = self.runtime
        self.prepared.graph = Graph(TASKS)
        self.prepared.native = mock.Mock(socket=self.runtime / "native.sock")
        self.prepared.native.request.return_value = {"status": "ok"}
        self.prepared.wait_manager = mock.Mock()

    def calls(self):
        return [(call.args[0], call.kwargs) for call in self.prepared.native.request.call_args_list]

    def test_releasing_one_endpoint_keeps_shared_dependencies(self):
        self.prepared.demand("endpoint:web", ["devenv:processes:web"])
        self.prepared.demand("endpoint:mobile", ["devenv:processes:mobile"])
        self.prepared.native.request.reset_mock()
        self.prepared.demand("endpoint:web")
        self.assertEqual(
            self.calls(),
            [("start", {"names": ["database", "mobile"]}), ("stop", {"name": "web"})],
        )
        self.assertEqual(json.loads((self.runtime / "demand.json").read_text()), {"endpoint:mobile": ["devenv:processes:mobile"]})

    def test_stop_failures_are_left_for_the_collector(self):
        self.prepared.demand("endpoint:web", ["devenv:processes:web"])
        self.prepared.native.request.side_effect = [RuntimeError("still starting"), RuntimeError("still starting")]
        self.prepared.demand("endpoint:web")
        self.assertEqual(json.loads((self.runtime / "demand.json").read_text()), {})


class ActivationTest(unittest.TestCase):
    def test_restores_captured_variables_except_those_owned_by_the_caller(self):
        prepared = {
            "variables": {
                "HOME": {"type": "exported", "value": "/build"},
                "PROJECT_RUNTIME_FILE": {"type": "exported", "value": "/stale"},
                "DATABASE": {"type": "exported", "value": "it's"},
                "local": {"type": "var", "value": "x"},
                "list": {"type": "array", "value": ["a b", "c"]},
            },
            "bashFunctions": {"greet": "echo hi"},
        }
        lines = activation_script(prepared, {"PATH": "/host/bin"})
        self.assertNotIn("HOME", "\n".join(lines))
        self.assertNotIn("/stale", "\n".join(lines))
        self.assertIn("DATABASE='it'\"'\"'s'", lines)
        self.assertIn("export DATABASE", lines)
        self.assertNotIn("export local", lines)
        self.assertIn("declare -a list=('a b' c)", lines)
        self.assertIn('export PATH="${PATH:-}":/host/bin', lines)


if __name__ == "__main__":
    unittest.main()

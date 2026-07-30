"""Shared fixtures and helpers for the repository-wide test suite.

Every project in this repo is an independent Ansible project (its own
ansible.cfg, roles/, playbooks/, requirements.yml and CI workflow), but
they share a set of conventions. These helpers discover the projects and
give the tests a single place to parse YAML, walk tasks and run the real
Ansible engine against a role's guard logic.
"""
from __future__ import annotations

import dataclasses
import json
import os
import pathlib
import re
import subprocess
import tempfile

import pytest
import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent

# Task keywords that are not module names, so they must be skipped when
# working out which module a task actually calls.
TASK_KEYWORDS = {
    "name", "when", "block", "rescue", "always", "register", "loop",
    "with_items", "with_dict", "with_fileglob", "loop_control", "delegate_to",
    "delegate_facts", "become", "become_user", "become_method", "ignore_errors",
    "ignore_unreachable", "failed_when", "changed_when", "tags", "no_log",
    "vars", "until", "retries", "delay", "run_once", "check_mode", "notify",
    "environment", "any_errors_fatal", "args", "listen", "throttle",
    "connection", "remote_user", "collections", "module_defaults", "timeout",
    "poll", "async", "diff", "debugger", "port",
}

PLAY_TASK_SECTIONS = ("pre_tasks", "tasks", "post_tasks", "handlers")


@dataclasses.dataclass(frozen=True)
class Project:
    """One self-contained Ansible project directory."""

    path: pathlib.Path

    @property
    def name(self) -> str:
        return self.path.name

    @property
    def roles_dir(self) -> pathlib.Path:
        return self.path / "roles"

    @property
    def playbooks_dir(self) -> pathlib.Path:
        return self.path / "playbooks"

    def roles(self) -> list[pathlib.Path]:
        if not self.roles_dir.is_dir():
            return []
        return sorted(d for d in self.roles_dir.iterdir() if d.is_dir())

    def playbooks(self) -> list[pathlib.Path]:
        if not self.playbooks_dir.is_dir():
            return []
        return sorted(self.playbooks_dir.glob("*.yml"))

    def task_files(self) -> list[pathlib.Path]:
        return sorted(self.roles_dir.glob("*/tasks/*.yml")) if self.roles_dir.is_dir() else []

    def yaml_files(self) -> list[pathlib.Path]:
        return [
            f for f in sorted(self.path.rglob("*.yml"))
            if ".extracted" not in f.parts
        ]

    @property
    def workflow(self) -> pathlib.Path:
        return REPO_ROOT / ".github" / "workflows" / f"{self.name}-ci.yml"

    def __str__(self) -> str:  # pragma: no cover - pytest ids only
        return self.name


def discover_projects() -> list[Project]:
    """Every directory that is an Ansible project (identified by its ansible.cfg)."""
    return [
        Project(p)
        for p in sorted(REPO_ROOT.iterdir())
        if p.is_dir() and (p / "ansible.cfg").is_file()
    ]


PROJECTS = discover_projects()


def pytest_generate_tests(metafunc):
    """Parametrize any test taking a `project` argument over every project."""
    if "project" in metafunc.fixturenames:
        metafunc.parametrize("project", PROJECTS, ids=[p.name for p in PROJECTS])


def load_yaml(path: pathlib.Path):
    """Parse a YAML file, raising a readable error instead of a bare exception."""
    try:
        return yaml.safe_load(path.read_text())
    except yaml.YAMLError as exc:  # pragma: no cover - only on a broken file
        raise AssertionError(f"{path} is not valid YAML: {exc}") from exc


def walk_tasks(node):
    """Yield every task in a task list, recursing into block/rescue/always.

    A task carrying `block:` is a structural container rather than an
    action, so only its children are yielded, never the container itself.
    """
    if not isinstance(node, list):
        return
    for task in node:
        if not isinstance(task, dict):
            continue
        nested = False
        for section in ("block", "rescue", "always"):
            if section in task:
                nested = True
                yield from walk_tasks(task[section])
        if not nested:
            yield task


def tasks_in_file(path: pathlib.Path):
    """Yield every task in a role task file or a playbook, blocks included."""
    docs = load_yaml(path)
    if not isinstance(docs, list):
        return
    if path.parent.name == "playbooks":
        for play in docs:
            if not isinstance(play, dict):
                continue
            for section in PLAY_TASK_SECTIONS:
                yield from walk_tasks(play.get(section))
    else:
        yield from walk_tasks(docs)


def module_of(task: dict) -> str | None:
    """The module a task calls, or None for a pure-keyword task."""
    candidates = [k for k in task if k not in TASK_KEYWORDS]
    return candidates[0] if candidates else None


# --------------------------------------------------------------------------
# Guard harness: run a role's validation logic through the real Ansible engine
# --------------------------------------------------------------------------

# Names Ansible always provides, so a task referencing them is still runnable.
_ALWAYS_AVAILABLE = {"ansible_check_mode", "omit", "item"}
_NAME_RE = re.compile(r"[a-zA-Z_][a-zA-Z0-9_]*")


def _referenced_names(task: dict) -> set[str]:
    return set(_NAME_RE.findall(yaml.safe_dump(task, default_flow_style=False)))


def guard_tasks(role_dir: pathlib.Path) -> list[dict]:
    """The assert/set_fact tasks of a role that can run without any real target.

    Preflight roles interleave pure validation (assert/set_fact) with tasks
    that talk to vCenter, SCVMM or a guest over WinRM. The validation logic
    is the part worth testing hermetically, so this keeps assert/set_fact
    tasks and drops anything that depends - directly or transitively - on a
    value only a real infrastructure call could produce.
    """
    tasks = load_yaml(role_dir / "tasks" / "main.yml")
    if not isinstance(tasks, list):
        return []

    kept = [
        t for t in walk_tasks(tasks)
        if {"ansible.builtin.assert", "ansible.builtin.set_fact"} & set(t)
    ]
    # Anything produced by a task we are not running is unavailable.
    unavailable = {
        t["register"] for t in walk_tasks(tasks)
        if "register" in t and t not in kept
    }

    # Dropping a task makes the facts it would have set unavailable too, so
    # iterate to a fixpoint rather than filtering once.
    while True:
        survivors = []
        newly_unavailable = set()
        for task in kept:
            if _referenced_names(task) & unavailable - _ALWAYS_AVAILABLE:
                newly_unavailable |= set(task.get("ansible.builtin.set_fact") or {})
            else:
                survivors.append(task)
        if not newly_unavailable - unavailable:
            return survivors
        unavailable |= newly_unavailable
        kept = survivors


def run_guards(role_dir: pathlib.Path, variables: dict) -> tuple[bool, str]:
    """Run a role's guard tasks under real Ansible. Returns (passed, output)."""
    tasks = guard_tasks(role_dir)
    play = [{
        "name": f"guards for {role_dir.name}",
        "hosts": "localhost",
        "connection": "local",
        "gather_facts": False,
        "tasks": tasks,
    }]
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = pathlib.Path(tmp)
        playbook = tmp_path / "guards.yml"
        playbook.write_text(yaml.safe_dump(play, default_flow_style=False))
        extra_vars = tmp_path / "vars.json"
        extra_vars.write_text(json.dumps(variables))
        env = dict(
            os.environ,
            ANSIBLE_LOCALHOST_WARNING="0",
            ANSIBLE_INVENTORY_UNPARSED_WARNING="0",
            ANSIBLE_RETRY_FILES_ENABLED="0",
            ANSIBLE_DEPRECATION_WARNINGS="0",
        )
        result = subprocess.run(
            ["ansible-playbook", str(playbook), "-i", "localhost,",
             "-e", f"@{extra_vars}"],
            capture_output=True, text=True, env=env,
        )
    return result.returncode == 0, result.stdout + result.stderr


@pytest.fixture(scope="session")
def repo_root() -> pathlib.Path:
    return REPO_ROOT

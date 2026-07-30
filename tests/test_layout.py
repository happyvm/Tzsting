"""Every project follows the same layout and is wired into CI.

These are the conventions that make the projects interchangeable for an
operator: same entry points, same lint configuration, same inventory
example, and a CI workflow that actually watches the right directory and
syntax-checks a playbook that exists. A project that quietly drifts from
them still passes its own lint job, so nothing else would catch it.
"""
from __future__ import annotations

import re

import pytest
import yaml

from conftest import REPO_ROOT, load_yaml

REQUIRED_FILES = [
    "ansible.cfg",
    "requirements.yml",
    "README.md",
    ".yamllint",
    ".ansible-lint",
    ".gitignore",
    "inventory/hosts.yml.example",
    "inventory/group_vars/all.yml",
]


@pytest.mark.parametrize("relative", REQUIRED_FILES)
def test_project_has_required_file(project, relative):
    assert (project.path / relative).is_file(), (
        f"{project.name} is missing {relative}, which every other project in "
        f"this repo provides"
    )


def test_project_has_at_least_one_playbook(project):
    assert project.playbooks(), f"{project.name} has no playbooks/*.yml"


def test_project_has_at_least_one_role(project):
    assert project.roles(), f"{project.name} has no roles/"


def test_gitignore_excludes_generated_inventory(project):
    """inventory/hosts.yml is generated from the example and must stay untracked."""
    ignored = (project.path / ".gitignore").read_text().split()
    assert "inventory/hosts.yml" in ignored, (
        f"{project.name}/.gitignore must ignore inventory/hosts.yml - CI copies "
        f"hosts.yml.example over it, and a committed copy would shadow that"
    )


def test_ansible_cfg_points_at_local_inventory_and_roles(project):
    cfg = (project.path / "ansible.cfg").read_text()
    assert re.search(r"^\s*inventory\s*=\s*inventory/hosts\.yml", cfg, re.M), (
        f"{project.name}/ansible.cfg must set inventory = inventory/hosts.yml"
    )
    assert re.search(r"^\s*roles_path\s*=\s*roles", cfg, re.M), (
        f"{project.name}/ansible.cfg must set roles_path = roles"
    )


def test_ansible_lint_excludes_generated_paths(project):
    """.extracted/ and the generated inventory must not be linted."""
    config = load_yaml(project.path / ".ansible-lint") or {}
    excluded = set(config.get("exclude_paths") or [])
    assert "inventory/hosts.yml" in excluded, (
        f"{project.name}/.ansible-lint must exclude inventory/hosts.yml"
    )


# --- CI wiring -------------------------------------------------------------


def test_project_has_ci_workflow(project):
    assert project.workflow.is_file(), (
        f"{project.name} has no .github/workflows/{project.name}-ci.yml, so "
        f"nothing lints it on push"
    )


def test_workflow_watches_its_own_project(project):
    workflow = load_yaml(project.workflow)
    # `on` is parsed as the boolean True by YAML 1.1, which is what PyYAML does.
    triggers = workflow.get("on", workflow.get(True))
    assert triggers, f"{project.workflow.name} declares no triggers"
    for event in ("push", "pull_request"):
        paths = triggers[event]["paths"]
        assert f"{project.name}/**" in paths, (
            f"{project.workflow.name} does not watch {project.name}/** on "
            f"{event}, so changes to the project would not trigger its CI"
        )
        assert f".github/workflows/{project.name}-ci.yml" in paths, (
            f"{project.workflow.name} does not watch itself on {event}"
        )


def test_workflow_working_directory_is_the_project(project):
    workflow = load_yaml(project.workflow)
    working_dir = workflow.get("defaults", {}).get("run", {}).get("working-directory")
    assert working_dir == project.name, (
        f"{project.workflow.name} runs in {working_dir!r}, expected "
        f"{project.name!r} - every step is written relative to the project root"
    )


def _syntax_check_coverage(project) -> tuple[set[str], bool]:
    """What the workflow's --syntax-check step covers.

    Projects with a single entry point name it directly; the multi-playbook
    ones loop over `playbooks/*.yml`, which covers everything including
    playbooks added later. Both forms are fine.
    """
    workflow_text = project.workflow.read_text()
    assert "--syntax-check" in workflow_text, (
        f"{project.workflow.name} has no `ansible-playbook ... --syntax-check` step"
    )
    globbed = bool(re.search(r"for\s+\w+\s+in\s+playbooks/\*\.yml", workflow_text))
    named = set(re.findall(r"ansible-playbook\s+(playbooks/\S+\.yml)", workflow_text))
    return named, globbed


def test_workflow_syntax_checks_existing_playbooks(project):
    """Any playbook the workflow names by hand must actually exist."""
    named, globbed = _syntax_check_coverage(project)
    assert named or globbed, (
        f"{project.workflow.name} syntax-checks nothing identifiable"
    )
    for playbook in sorted(named):
        assert (project.path / playbook).is_file(), (
            f"{project.workflow.name} syntax-checks {playbook}, which does not "
            f"exist in {project.name}"
        )


def test_every_playbook_is_syntax_checked(project):
    """A playbook nobody syntax-checks is a playbook CI does not cover."""
    named, globbed = _syntax_check_coverage(project)
    if globbed:
        return
    missing = sorted({f"playbooks/{p.name}" for p in project.playbooks()} - named)
    assert not missing, (
        f"{project.workflow.name} never syntax-checks {missing} - name them in "
        f"the --syntax-check step, or loop over playbooks/*.yml like "
        f"ansible-snapshot does"
    )


def test_no_orphan_workflows(repo_root):
    """Every *-ci.yml workflow corresponds to a project that still exists."""
    from conftest import PROJECTS

    names = {p.name for p in PROJECTS}
    orphans = []
    for workflow in sorted((repo_root / ".github" / "workflows").glob("*-ci.yml")):
        project_name = workflow.name[: -len("-ci.yml")]
        if project_name not in names:
            orphans.append(workflow.name)
    assert not orphans, f"workflows without a matching project: {orphans}"


def test_committed_inventory_is_absent(project):
    """A real inventory/hosts.yml must never be committed."""
    assert not (project.path / "inventory" / "hosts.yml").exists(), (
        f"{project.name}/inventory/hosts.yml is present - it is generated from "
        f"hosts.yml.example and may hold real hostnames"
    )


def test_inventory_example_parses(project):
    assert isinstance(load_yaml(project.path / "inventory" / "hosts.yml.example"), dict)

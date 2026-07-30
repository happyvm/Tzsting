"""Every project follows the same layout, and CI is wired to find it.

These are the conventions that make the projects interchangeable for an
operator: same entry points, same lint configuration, same inventory
example. A project that quietly drifts from them still passes lint, so
nothing else would catch it.

Since the 39 per-project workflows were merged into `ansible-projects.yml`,
CI discovers projects by their `ansible.cfg` marker rather than from a list.
The tests below therefore check the shape of that single workflow - that it
keeps all four checks, covers every playbook, and stays list-free - instead
of checking 39 near-identical files against each other.
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


POWERSHELL_QUALITY = REPO_ROOT / ".github" / "workflows" / "powershell-quality.yml"


def test_powershell_quality_covers_every_extraction_it_runs():
    """Its path filter must trigger for every project it then analyses.

    The workflow is scoped so a doc-only push does not pay for installing
    PSScriptAnalyzer. That scoping is only safe while the filter still
    matches every project the workflow extracts from - otherwise a change to
    a project's embedded PowerShell would silently never be analysed.
    """
    workflow = load_yaml(POWERSHELL_QUALITY)
    triggers = workflow.get("on", workflow.get(True))
    text = POWERSHELL_QUALITY.read_text()
    extracted = set(re.findall(r"python3 (\S+?)/scripts/extract_embedded_scripts\.py", text))
    assert extracted, "no extraction steps found in powershell-quality.yml"
    for event in ("push", "pull_request"):
        paths = set(triggers[event]["paths"])
        missing = sorted(p for p in extracted if f"{p}/**" not in paths)
        assert not missing, (
            f"powershell-quality.yml extracts from {missing} on {event} but its "
            f"path filter does not match them - their embedded PowerShell would "
            f"stop being analysed"
        )


def test_powershell_quality_matches_standalone_scripts_anywhere(repo_root):
    """Every .ps1/.psm1/.psd1 in the repo must still trigger the workflow."""
    workflow = load_yaml(POWERSHELL_QUALITY)
    triggers = workflow.get("on", workflow.get(True))
    for event in ("push", "pull_request"):
        paths = set(triggers[event]["paths"])
        for suffix in ("ps1", "psm1", "psd1"):
            assert f"**/*.{suffix}" in paths, (
                f"powershell-quality.yml does not match **/*.{suffix} on {event}, "
                f"so a standalone script added outside the six extraction "
                f"projects would go unanalysed"
            )


def test_no_workflow_uses_yaml_anchors(repo_root):
    """GitHub Actions does not expand YAML anchors, so they silently misfire."""
    offenders = []
    for workflow in sorted((repo_root / ".github" / "workflows").glob("*.yml")):
        for number, line in enumerate(workflow.read_text().splitlines(), 1):
            if re.search(r":\s*[&*][A-Za-z_][\w-]*\s*$", line):
                offenders.append(f"{workflow.name}:{number}")
    assert not offenders, (
        f"YAML anchor/alias used in {offenders} - the Actions workflow parser "
        f"does not support them, so the value would not expand"
    )


ANSIBLE_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "ansible-projects.yml"


def test_consolidated_workflow_exists():
    assert ANSIBLE_WORKFLOW.is_file(), (
        "ansible-projects.yml is gone - it is the only thing linting the "
        "Ansible projects since the 39 per-project workflows were merged"
    )


def test_no_per_project_workflows_remain(repo_root):
    """The per-project files were merged; a stray one would lint twice.

    They were 39 files for three distinct shapes, and reintroducing one
    means the next shared change has to be made in two places again.
    """
    leftovers = sorted(
        w.name for w in (repo_root / ".github" / "workflows").glob("*-ci.yml")
    )
    assert not leftovers, (
        f"per-project workflow(s) {leftovers} are back - the Ansible projects "
        f"are linted by ansible-projects.yml's matrix now"
    )


def test_consolidated_workflow_discovers_projects_by_ansible_cfg():
    """Discovery must stay marker-based so a new project needs no CI edit."""
    text = ANSIBLE_WORKFLOW.read_text()
    assert "ansible.cfg" in text, (
        "ansible-projects.yml no longer keys off ansible.cfg to find projects - "
        "if it now carries a hardcoded list, a new project is silently unlinted"
    )
    from conftest import PROJECTS

    for project in PROJECTS:
        assert f"'{project.name}'" not in text or project.name == "ansible-resizedisk", (
            f"{project.name} is named explicitly in ansible-projects.yml - the "
            f"matrix is meant to be derived from the changed paths, not listed"
        )


@pytest.mark.parametrize(
    "command",
    [
        "ansible-galaxy collection install -r requirements.yml",
        "yamllint .",
        "ansible-lint",
        "--syntax-check",
    ],
)
def test_consolidated_workflow_keeps_every_check(command):
    """The merge must not have quietly dropped one of the four checks.

    This reads the lint job's actual steps rather than searching the file
    text: `ansible-lint` also appears in the `pip install` line, so a
    substring match over the whole workflow would still pass with the
    ansible-lint step deleted.
    """
    workflow = load_yaml(ANSIBLE_WORKFLOW)
    runs = [
        step["run"].strip()
        for step in workflow["jobs"]["lint"]["steps"]
        if "run" in step and not step["run"].strip().startswith("pip install")
    ]
    assert any(command in run for run in runs), (
        f"no step in ansible-projects.yml's lint job runs `{command}`, which "
        f"every per-project workflow used to run. Steps found: {runs}"
    )


def test_consolidated_workflow_syntax_checks_every_playbook():
    """Looping over playbooks/*.yml is what makes coverage automatic.

    Half the old workflows named a single playbook instead, and silently
    stopped covering the rest as soon as a second one was added.
    """
    text = ANSIBLE_WORKFLOW.read_text()
    assert re.search(r"playbooks=\(playbooks/\*\.yml\)", text), (
        "ansible-projects.yml does not glob playbooks/*.yml for --syntax-check, "
        "so newly added playbooks would not be covered"
    )
    assert "nullglob" in text, (
        "the playbook glob needs nullglob, or an empty playbooks/ directory "
        "would hand ansible-playbook the literal glob string"
    )


def test_consolidated_workflow_does_not_fail_fast():
    """One project failing must not hide the state of the other 38."""
    workflow = load_yaml(ANSIBLE_WORKFLOW)
    assert workflow["jobs"]["lint"]["strategy"]["fail-fast"] is False, (
        "ansible-projects.yml's lint matrix is fail-fast, so the first failing "
        "project would cancel the rest and hide their results"
    )


def test_consolidated_workflow_skips_cleanly_when_nothing_changed():
    """An empty matrix must be guarded, not handed to fromJson."""
    workflow = load_yaml(ANSIBLE_WORKFLOW)
    condition = workflow["jobs"]["lint"].get("if", "")
    assert "projects != '[]'" in condition, (
        "ansible-projects.yml's lint job has no guard for an empty project "
        "list - a push touching no project should skip it, not run an empty "
        "matrix"
    )


def test_committed_inventory_is_absent(project):
    """A real inventory/hosts.yml must never be committed."""
    assert not (project.path / "inventory" / "hosts.yml").exists(), (
        f"{project.name}/inventory/hosts.yml is present - it is generated from "
        f"hosts.yml.example and may hold real hostnames"
    )


def test_inventory_example_parses(project):
    assert isinstance(load_yaml(project.path / "inventory" / "hosts.yml.example"), dict)

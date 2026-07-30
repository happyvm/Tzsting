"""Invariants about roles, tasks and declared dependencies.

ansible-lint checks each project's syntax and style; these tests check the
things it cannot see - that a role a playbook includes actually exists,
that every collection a project calls into is declared in the
requirements.yml CI installs from, and that no role is left stranded.
"""
from __future__ import annotations

import re

import pytest

from conftest import load_yaml, module_of, tasks_in_file

# Collection namespaces that ship with ansible-core, so they need no entry
# in requirements.yml.
BUILTIN_NAMESPACES = {"ansible.builtin", "ansible.legacy"}

FQCN_RE = re.compile(r"^([a-z0-9_]+\.[a-z0-9_]+)\.[a-z0-9_]+$")
ROLE_INCLUDE_MODULES = {
    "ansible.builtin.include_role", "include_role",
    "ansible.builtin.import_role", "import_role",
}


def _included_role_names(project):
    """Every role name pulled in via include_role/import_role or `roles:`.

    Both the block form (`include_role:\\n  name: x`) and the inline
    flow-mapping form (`include_role: {name: x}`) are used in this repo, so
    this reads the parsed YAML rather than matching source text.
    """
    names = set()
    for path in project.task_files() + project.playbooks():
        for task in tasks_in_file(path):
            for key in ROLE_INCLUDE_MODULES & set(task):
                value = task[key]
                if isinstance(value, dict) and isinstance(value.get("name"), str):
                    names.add(value["name"])
    for playbook in project.playbooks():
        for play in load_yaml(playbook) or []:
            if not isinstance(play, dict):
                continue
            for role in play.get("roles") or []:
                name = role["role"] if isinstance(role, dict) else role
                if isinstance(name, str):
                    names.add(name)
    return names


def declared_collections(project) -> set[str]:
    data = load_yaml(project.path / "requirements.yml") or {}
    out = set()
    for entry in data.get("collections") or []:
        out.add(entry["name"] if isinstance(entry, dict) else entry)
    return out


def used_collections(project) -> set[str]:
    """Collection namespaces this project actually calls a module from."""
    used = set()
    for path in project.task_files() + project.playbooks():
        for task in tasks_in_file(path):
            module = module_of(task)
            if not module:
                continue
            match = FQCN_RE.match(module)
            if match and match.group(1) not in BUILTIN_NAMESPACES:
                used.add(match.group(1))
    return used


def referenced_roles(project) -> set[str]:
    """This project's own roles that something includes.

    A dotted name is a collection role (e.g. azure.azcollection.azure_arc),
    not one of the project's local roles.
    """
    return {name for name in _included_role_names(project) if "." not in name}


def collection_roles(project) -> set[str]:
    """Namespaced roles pulled from a collection, e.g. azure.azcollection.azure_arc."""
    return {name for name in _included_role_names(project) if "." in name}


# --- roles -----------------------------------------------------------------


def test_referenced_roles_exist(project):
    present = {r.name for r in project.roles()}
    missing = sorted(referenced_roles(project) - present)
    assert not missing, (
        f"{project.name} includes role(s) {missing} that do not exist under "
        f"roles/ - the playbook would fail at runtime"
    )


def test_no_unreferenced_roles(project):
    present = {r.name for r in project.roles()}
    orphans = sorted(present - referenced_roles(project))
    assert not orphans, (
        f"{project.name} has role(s) {orphans} that no playbook includes - "
        f"either wire them up or delete them"
    )


def test_every_role_has_tasks_main(project):
    for role in project.roles():
        assert (role / "tasks" / "main.yml").is_file(), (
            f"{project.name}/roles/{role.name} has no tasks/main.yml"
        )


def test_role_task_files_are_task_lists(project):
    for path in project.task_files():
        parsed = load_yaml(path)
        assert isinstance(parsed, list), (
            f"{path.relative_to(project.path.parent)} must be a YAML list of "
            f"tasks, got {type(parsed).__name__}"
        )


# --- tasks -----------------------------------------------------------------


def test_every_task_is_named(project):
    """An unnamed task is unreadable in AAP job output and in a failure report."""
    unnamed = []
    for path in project.task_files() + project.playbooks():
        for task in tasks_in_file(path):
            if not task.get("name"):
                unnamed.append(f"{path.relative_to(project.path)}: {module_of(task)}")
    assert not unnamed, f"{project.name} has unnamed task(s): {unnamed}"


def test_modules_use_fully_qualified_names(project):
    """Short module names resolve differently depending on installed collections."""
    short = []
    for path in project.task_files() + project.playbooks():
        for task in tasks_in_file(path):
            module = module_of(task)
            if module and "." not in module:
                short.append(f"{path.relative_to(project.path)}: {module}")
    assert not short, (
        f"{project.name} calls module(s) by short name: {short} - use the FQCN"
    )


def test_every_play_is_named(project):
    for playbook in project.playbooks():
        for index, play in enumerate(load_yaml(playbook) or []):
            assert isinstance(play, dict) and play.get("name"), (
                f"{playbook.relative_to(project.path)} play #{index + 1} has no name"
            )


# --- declared dependencies -------------------------------------------------


def test_used_collections_are_declared(project):
    """CI installs only what requirements.yml lists, so anything used must be there."""
    missing = sorted(used_collections(project) - declared_collections(project))
    assert not missing, (
        f"{project.name} calls modules from {missing} but requirements.yml does "
        f"not declare them - CI installs from that file, so the playbook would "
        f"fail with an unresolved module"
    )


def test_collection_roles_are_declared(project):
    """A role borrowed from a collection needs that collection declared too."""
    declared = declared_collections(project)
    missing = sorted(
        role for role in collection_roles(project)
        if ".".join(role.split(".")[:2]) not in declared
    )
    assert not missing, (
        f"{project.name} includes collection role(s) {missing} whose collection "
        f"is not in requirements.yml"
    )


def _collections_pinned_somewhere() -> dict[str, set[str]]:
    """Collections this repo pins in at least one project -> the pins used."""
    from conftest import PROJECTS

    pinned: dict[str, set[str]] = {}
    for other in PROJECTS:
        data = load_yaml(other.path / "requirements.yml") or {}
        for entry in data.get("collections") or []:
            if isinstance(entry, dict) and entry.get("version"):
                pinned.setdefault(entry["name"], set()).add(entry["version"])
    return pinned


def test_requirements_pin_a_version(project):
    """A collection pinned anywhere in this repo must not be unpinned here.

    CI reinstalls collections from scratch on every run, so an unpinned
    entry lets an upstream release change behaviour with no commit. Rather
    than invent a floor for a collection nobody has pinned yet, this only
    enforces the constraint where the repo has already chosen one.
    """
    pinned_elsewhere = _collections_pinned_somewhere()
    data = load_yaml(project.path / "requirements.yml") or {}
    drifted = sorted(
        entry["name"] for entry in data.get("collections") or []
        if isinstance(entry, dict)
        and not entry.get("version")
        and entry["name"] in pinned_elsewhere
    )
    assert not drifted, (
        f"{project.name}/requirements.yml leaves {drifted} unpinned, but other "
        f"projects here pin it to "
        f"{ {c: sorted(pinned_elsewhere[c]) for c in drifted} }"
    )


# --- secrets ---------------------------------------------------------------


def test_no_plaintext_secrets_in_group_vars(project):
    """Secrets must come from vault/AAP, never a literal in group_vars."""
    group_vars = project.path / "inventory" / "group_vars" / "all.yml"
    offenders = []
    for key, value in (load_yaml(group_vars) or {}).items():
        if not re.search(r"password|secret|token|passphrase|api_key", key, re.I):
            continue
        if not isinstance(value, str):
            continue
        # A vault-sourced value is a Jinja reference, not a literal.
        if value == "" or "{{" in value:
            continue
        offenders.append(key)
    assert not offenders, (
        f"{project.name}/inventory/group_vars/all.yml holds literal value(s) for "
        f"{offenders} - reference a vault_* variable instead"
    )

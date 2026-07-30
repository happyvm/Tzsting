"""The preflight guardrails, exercised through the real Ansible engine.

Almost every project interpolates request-supplied values into
single-quoted PowerShell string literals on a management server (SCVMM, a
Hyper-V host, a WSUS/SCCM console). The preflight `assert` tasks are the
only thing standing between a ServiceNow field and command execution
there, and `--syntax-check` cannot tell whether they actually reject
anything.

These tests run the guards for real: a temporary playbook holding the
role's own assert/set_fact tasks, driven by `ansible-playbook`, with the
value under test passed as an extra-var. What passes and what fails is
then the engine's answer, not a re-implementation of Jinja in Python.
"""
from __future__ import annotations

import re

import pytest

from conftest import PROJECTS, REPO_ROOT, load_yaml, run_guards, tasks_in_file

# A value that breaks out of a single-quoted PowerShell string literal and
# starts executing. Any guard that lets this through is not a guard.
POWERSHELL_BREAKOUT = "x'; Remove-Item C:\\ -Recurse -Force #"

# The expression a guard validates: a (possibly dotted) variable, an
# optional filter chain, then `is regex(...)` / `is match(...)`.
GUARD_RE = re.compile(
    r"([a-z_]\w*(?:\.[a-z_]\w*)*)\s*"
    r"(?:\|\s*[a-z_]\w*(?:\([^()]*\))?\s*)*"
    r"is\s+(?:regex|match)\("
)
IDENT_RE = re.compile(r"[a-z_]\w*(?:\.[a-z_]\w*)*")
# Jinja keywords, filters and tests, none of which are variables.
NOT_VARIABLES = {
    "and", "or", "not", "is", "in", "if", "else", "true", "false", "none",
    "default", "length", "bool", "int", "float", "string", "trim", "lower",
    "upper", "regex", "match", "search", "defined", "undefined", "list",
    "count", "first", "last", "join", "map", "select", "reject", "abs",
    "round", "version", "type_debug", "quote", "b64encode", "b64decode",
}


def _base_variables(condition: str) -> set[str]:
    """The distinct top-level variables a condition reads."""
    stripped = re.sub(r"'[^']*'|\"[^\"]*\"", "", condition)
    return {
        token.split(".")[0]
        for token in IDENT_RE.findall(stripped)
        if token.split(".")[0] not in NOT_VARIABLES
    }


def _guard_conditions(project):
    """(role, condition, guarded_expression) for every self-gated guard.

    A guard whose condition also reads a *different* variable is gated on
    something else - `not storeonce_syslog_enabled | bool or
    storeonce_syslog_endpoint is match(...)` only applies when the feature
    is switched on. Turning such a gate on generically would mean guessing,
    so those are left to the per-project tests below.
    """
    found = []
    for path in project.task_files():
        for task in tasks_in_file(path):
            spec = task.get("ansible.builtin.assert")
            if not isinstance(spec, dict):
                continue
            conditions = spec.get("that")
            if isinstance(conditions, str):
                conditions = [conditions]
            for condition in conditions or []:
                if not isinstance(condition, str):
                    continue
                match = GUARD_RE.search(condition)
                if not match:
                    continue
                guarded = match.group(1)
                if _base_variables(condition) != {guarded.split(".")[0]}:
                    continue
                found.append((path.parent.parent.name, condition, guarded))
    return found


def _nested(path: str, value):
    """Build the variable structure needed to set a dotted expression."""
    head, *rest = path.split(".")
    for key in reversed(rest):
        value = {key: value}
    return {head: value}


ALL_GUARDS = [
    pytest.param(project, condition, expression,
                 id=f"{project.name}::{role}::{expression}")
    for project in PROJECTS
    for role, condition, expression in _guard_conditions(project)
]


@pytest.mark.parametrize("guard_project, condition, expression", ALL_GUARDS)
def test_interpolation_guard_rejects_a_powershell_breakout(
    guard_project, condition, expression, tmp_path
):
    """Every `is regex(...)` guard must reject a value containing a quote.

    The condition is lifted verbatim out of the role and evaluated on its
    own, so this stays true as the guards are edited and cannot drift into
    testing a copy of them.
    """
    passed, output = _evaluate(
        condition, _nested(expression, POWERSHELL_BREAKOUT), tmp_path
    )
    assert not passed, (
        f"{guard_project.name}: the guard `{condition}` accepted "
        f"{POWERSHELL_BREAKOUT!r}. That value is interpolated into a "
        f"single-quoted PowerShell literal, so accepting it means the quote "
        f"closes the string and the rest runs as PowerShell.\n{output}"
    )


def _evaluate(condition: str, variables: dict, tmp_path) -> tuple[bool, str]:
    """Run a single assert condition through ansible-playbook."""
    import json
    import os
    import subprocess

    import yaml as _yaml

    play = [{
        "name": "guard",
        "hosts": "localhost",
        "connection": "local",
        "gather_facts": False,
        "tasks": [{
            "name": f"assert {condition}",
            "ansible.builtin.assert": {"that": [condition]},
        }],
    }]
    playbook = tmp_path / "guard.yml"
    playbook.write_text(_yaml.safe_dump(play, default_flow_style=False))
    extra_vars = tmp_path / "vars.json"
    extra_vars.write_text(json.dumps(variables))
    result = subprocess.run(
        ["ansible-playbook", str(playbook), "-i", "localhost,", "-e", f"@{extra_vars}"],
        capture_output=True, text=True,
        env=dict(os.environ, ANSIBLE_LOCALHOST_WARNING="0",
                 ANSIBLE_INVENTORY_UNPARSED_WARNING="0"),
    )
    return result.returncode == 0, result.stdout + result.stderr


# --- ansible-createvm: the policy caps and mutual exclusions ---------------

CREATEVM = REPO_ROOT / "ansible-createvm" / "roles" / "preflight_create_constraints"
CREATEVM_VALID = {
    "hypervisor_type": "vmware",
    "vm_name": "WINSRV01",
    "template_name": "Windows Server 2022 Template",
    "guest_os": "windows",
    "vcpu_count": 4,
    "memory_gb": 16,
    "createvm_max_vcpu_count": 32,
    "createvm_max_memory_gb": 512,
    "createvm_max_disk_gb": 4000,
    "vmware_datastore": "datastore-ssd",
    "network_name": "VLAN-Production",
    "vmware_cluster": "Prod-Cluster01",
}


def test_createvm_accepts_a_well_formed_request():
    passed, output = run_guards(CREATEVM, CREATEVM_VALID)
    assert passed, f"a valid create request was rejected:\n{output}"


@pytest.mark.parametrize(
    "description, overrides",
    [
        ("vm_name carrying a PowerShell breakout",
         {"vm_name": POWERSHELL_BREAKOUT}),
        ("template_name carrying a PowerShell breakout",
         {"template_name": POWERSHELL_BREAKOUT}),
        ("an unknown hypervisor_type", {"hypervisor_type": "xen"}),
        ("an unknown guest_os", {"guest_os": "solaris"}),
        ("vcpu_count above the policy cap", {"vcpu_count": 999}),
        ("vcpu_count of zero", {"vcpu_count": 0}),
        ("memory_gb above the policy cap", {"memory_gb": 99999}),
        ("disk_gb above the policy cap", {"disk_gb": 999999}),
        ("a computer_name past the 15-char NetBIOS limit",
         {"computer_name": "WORKSTATION-0123"}),
        ("domain_name and workgroup_name together",
         {"domain_name": "corp.local", "workgroup_name": "WORKGROUP",
          "domain_admin_username": "svc", "domain_admin_password": "x"}),
        ("a domain join with no credentials", {"domain_name": "corp.local"}),
        ("VMware placement with neither cluster nor host",
         {"vmware_cluster": "", "esxi_host": ""}),
        ("Hyper-V without SCVMM configured",
         {"hypervisor_type": "hyperv", "scvmm_server": ""}),
        ("an SCVMM vm_path that is not a Windows path",
         {"hypervisor_type": "hyperv", "scvmm_server": "scvmm01",
          "vm_host": "hv01", "vm_path": "/mnt/vms"}),
    ],
)
def test_createvm_rejects_bad_requests(description, overrides):
    passed, output = run_guards(CREATEVM, {**CREATEVM_VALID, **overrides})
    assert not passed, (
        f"preflight_create_constraints accepted {description} "
        f"({overrides}):\n{output}"
    )


@pytest.mark.parametrize(
    "vm_name",
    ["WINSRV01", "web-01", "app_server.prod", "My Server 01", "A" * 80],
)
def test_createvm_accepts_realistic_vm_names(vm_name):
    """The safety regex must not reject names the CMDB legitimately produces."""
    passed, output = run_guards(
        CREATEVM, {**CREATEVM_VALID, "vm_name": vm_name, "computer_name": "SRV01"}
    )
    assert passed, f"vm_name {vm_name!r} was rejected:\n{output}"


def test_createvm_defaults_computer_name_to_vm_name():
    """computer_name is optional and falls back to vm_name.

    The fallback is observable through the NetBIOS check: with no
    computer_name supplied, a vm_name longer than 15 characters must be the
    thing that trips it. vm_name itself is allowed up to 80 characters, so
    a failure here can only come from the default having been applied.
    """
    request = {k: v for k, v in CREATEVM_VALID.items()}
    request["vm_name"] = "WORKSTATION-0123"  # 16 chars: fine as a vm_name
    passed, output = run_guards(CREATEVM, request)
    assert not passed, (
        f"a 16-character vm_name with no computer_name was accepted for a "
        f"Windows guest, so computer_name did not default to vm_name:\n{output}"
    )

    request["computer_name"] = "WS0123"
    passed, output = run_guards(CREATEVM, request)
    assert passed, (
        f"an explicit short computer_name should override the long vm_name:\n{output}"
    )


# --- ansible-resizedisk: guest credentials reach a PowerShell literal ------

RESIZEDISK_CONNECTIVITY = (
    REPO_ROOT / "ansible-resizedisk" / "roles" / "preflight_connectivity"
)


@pytest.mark.parametrize(
    "guest_username",
    ["svc_ansible", "CORP\\svc_ansible", "svc.ansible@corp.local", "Administrator"],
)
def test_resizedisk_accepts_realistic_guest_usernames(guest_username):
    passed, output = run_guards(
        RESIZEDISK_CONNECTIVITY,
        {"guest_username": guest_username, "guest_password": "irrelevant"},
    )
    assert passed, f"guest_username {guest_username!r} was rejected:\n{output}"


@pytest.mark.parametrize(
    "guest_username",
    [POWERSHELL_BREAKOUT, "a`nWrite-Host pwned", "a$(hostname)", ""],
)
def test_resizedisk_rejects_hostile_guest_usernames(guest_username):
    """guest_username lands in a PSCredential literal on the Hyper-V host."""
    passed, output = run_guards(
        RESIZEDISK_CONNECTIVITY,
        {"guest_username": guest_username, "guest_password": "irrelevant"},
    )
    assert not passed, (
        f"guest_username {guest_username!r} was accepted - it is interpolated "
        f"into PSCredential('...') in run_guest_command:\n{output}"
    )


def test_resizedisk_requires_a_credential():
    passed, _ = run_guards(RESIZEDISK_CONNECTIVITY, {"guest_username": "svc"})
    assert not passed, "a guest with neither password nor SSH key was accepted"


# --- every project's guards are reachable ----------------------------------


def test_every_project_has_a_preflight_role(project):
    """Validation is the shared contract; a project without it is an outlier."""
    roles = {r.name for r in project.roles()}
    assert any("preflight" in name for name in roles), (
        f"{project.name} has no preflight role: {sorted(roles)}"
    )


def test_preflight_runs_before_anything_else(project):
    """The first thing a playbook does must be to validate its input."""
    offenders = []
    for playbook in project.playbooks():
        for play in load_yaml(playbook) or []:
            if not isinstance(play, dict):
                continue
            tasks = play.get("tasks") or []
            names = []
            for task in tasks:
                for key in ("ansible.builtin.include_role", "ansible.builtin.import_role"):
                    value = task.get(key)
                    if isinstance(value, dict) and isinstance(value.get("name"), str):
                        names.append(value["name"])
            preflights = [i for i, n in enumerate(names) if "preflight" in n]
            if not preflights:
                continue
            # Two kinds of role may legitimately run before validation, and
            # neither mutates anything:
            #  - a lock, to close the window between "the name is free" and
            #    "the VM is created";
            #  - api_contract, which resolves the release-specific REST
            #    contract that preflight then validates - running it after
            #    would leave preflight with nothing to check.
            allowed_before = {
                i for i, n in enumerate(names)
                if "lock" in n or n == "api_contract"
            }
            if any(i not in allowed_before for i in range(preflights[0])):
                offenders.append(
                    f"{playbook.name}: {names[:preflights[0] + 1]}"
                )
    assert not offenders, (
        f"{project.name} runs roles before preflight validation: {offenders}"
    )

"""Backup verification before a destructive operation.

ANSIBLE.md is explicit that a snapshot is not a backup, and two playbooks
do something to a VM that no snapshot can undo: `ansible-deletevm` removes
its disks, and `ansible-inplace-upgrade` rewrites the running OS. Both now
run a `preflight_backup` role that refuses to proceed without a recent,
successful restore point on the backup server.

The value of that role is entirely in what it *refuses*, which is exactly
what a lint pass cannot see. These tests run it against a stand-in backup
server that answers with a scripted catalogue, so "no backup" and "a
backup from four days ago" produce a real refusal rather than an assumed
one.
"""
from __future__ import annotations

import datetime
import json
import os
import pathlib
import subprocess
import tempfile

import pytest
import yaml

from conftest import REPO_ROOT

# (project, variable prefix) - the same role, wired into both playbooks.
GUARDED = [
    ("ansible-deletevm", "deletevm"),
    ("ansible-inplace-upgrade", "inplace_upgrade"),
]

VM = "SRV01"


def _iso(hours_ago: float) -> str:
    stamp = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours_ago)
    return stamp.strftime("%Y-%m-%dT%H:%M:%S.000Z")


# The stand-in server runs as its own process, not a thread of the test.
# In-process it corrupts the `uri` module's output ("No start of json char
# found"): ansible-playbook is spawned as a child and the shared listening
# socket interferes with how the module's result is read back. A separate
# process is also closer to the real thing.
_SERVER_SOURCE = '''
import json, ssl, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SCENARIO = sys.argv[1]


class Catalogue(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _json(self, payload, code=200):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
        self._json({"access_token": "token", "token": "token"})

    def do_GET(self):
        # Re-read per request, so a test can change the catalogue without
        # restarting the server.
        with open(SCENARIO) as handle:
            self._json({"data": json.load(handle)})


server = HTTPServer(("127.0.0.1", int(sys.argv[2])), Catalogue)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[3], sys.argv[4])
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
'''


@pytest.fixture(scope="session")
def tls_cert(tmp_path_factory):
    """A throwaway self-signed certificate for the stand-in server."""
    directory = tmp_path_factory.mktemp("tls")
    cert, key = directory / "cert.pem", directory / "key.pem"
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-keyout", str(key),
         "-out", str(cert), "-days", "1", "-nodes", "-subj", "/CN=localhost"],
        check=True, capture_output=True,
    )
    return cert, key


def _free_port() -> int:
    import socket

    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


@pytest.fixture
def backup_server(tls_cert, tmp_path):
    """Start the stand-in backup server; yields a setter for its catalogue."""
    import time

    cert, key = tls_cert
    scenario = tmp_path / "catalogue.json"
    scenario.write_text("[]")
    source = tmp_path / "server.py"
    source.write_text(_SERVER_SOURCE)
    port = _free_port()
    process = subprocess.Popen(
        ["python3", str(source), str(scenario), str(port), str(cert), str(key)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )

    # Wait for the listener rather than sleeping a fixed amount.
    import socket

    for _ in range(100):
        with socket.socket() as probe:
            if probe.connect_ex(("127.0.0.1", port)) == 0:
                break
        time.sleep(0.05)
    else:  # pragma: no cover - only if the stand-in server fails to start
        process.kill()
        raise RuntimeError("the stand-in backup server never started listening")

    class Handle:
        def __init__(self):
            self.port = port

        @staticmethod
        def serve(points):
            scenario.write_text(json.dumps(points))

    try:
        yield Handle()
    finally:
        process.terminate()
        process.wait(timeout=5)


VEEAM_CONTRACT = {
    "veeam": {
        "12.1": {
            "api_version_header": "1.3-rev1",
            "restore_points_endpoint": "/api/v1/restorePoints",
            "results_key": "data",
            "name_field": "name",
            "timestamp_field": "creationTime",
            "status_field": "result",
            "success_values": ["Success", "Warning"],
        }
    }
}


def _run(project: str, prefix: str, variables: dict) -> tuple[bool, str]:
    """Run the project's preflight_backup role with the given variables."""
    project_dir = REPO_ROOT / project
    play = [{
        "name": "backup preflight",
        "hosts": "localhost",
        "connection": "local",
        "gather_facts": False,
        "tasks": [
            {"name": "verify", "ansible.builtin.include_role": {"name": "preflight_backup"}},
            {"name": "report", "ansible.builtin.debug": {
                "msg": f"STATE={{{{ {prefix}_backup_state }}}} "
                       f"DETAIL={{{{ {prefix}_backup_detail }}}}"}},
        ],
    }]
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = pathlib.Path(tmp)
        playbook = tmp_path / "backup.yml"
        playbook.write_text(yaml.safe_dump(play, default_flow_style=False))
        extra = tmp_path / "vars.json"
        extra.write_text(json.dumps(variables))
        result = subprocess.run(
            ["ansible-playbook", str(playbook), "-i", "localhost,", "-e", f"@{extra}"],
            capture_output=True, text=True, cwd=project_dir,
            env=dict(os.environ, ANSIBLE_LOCALHOST_WARNING="0",
                     ANSIBLE_INVENTORY_UNPARSED_WARNING="0"),
        )
    return result.returncode == 0, result.stdout + result.stderr


def _connected(prefix: str, port: int, **extra) -> dict:
    variables = {
        "vm_name": VM,
        f"{prefix}_backup_provider": "veeam",
        f"{prefix}_backup_release": "12.1.2",
        f"{prefix}_backup_hostname": "127.0.0.1",
        f"{prefix}_backup_port": port,
        f"{prefix}_backup_validate_certs": False,
        f"{prefix}_backup_username": "svc",
        f"{prefix}_backup_password": "secret",
        f"{prefix}_backup_api_contracts": VEEAM_CONTRACT,
    }
    variables.update(extra)
    return variables


# --- fails closed ---------------------------------------------------------


@pytest.mark.parametrize("project, prefix", GUARDED, ids=[p for p, _ in GUARDED])
class TestFailsClosed:
    """An unconfigured check must block, never wave the operation through."""

    def test_enabled_but_unconfigured_blocks(self, project, prefix):
        passed, output = _run(project, prefix, {"vm_name": VM})
        assert not passed, (
            f"{project} proceeded with backup verification enabled but no "
            f"backup server configured - a missing configuration must not read "
            f"as 'no backup needed':\n{output[-1500:]}"
        )

    def test_switching_it_off_is_recorded(self, project, prefix):
        passed, output = _run(project, prefix, {
            "vm_name": VM, f"{prefix}_backup_verification_enabled": False,
        })
        assert passed, output[-1500:]
        assert "STATE=disabled" in output, (
            f"{project} skipped the check without recording it in the artifact, "
            f"so the decision leaves no audit trail:\n{output[-1500:]}"
        )

    @pytest.mark.parametrize("provider", ["commvault", "rubrik", ""])
    def test_an_unsupported_provider_blocks(self, project, prefix, provider):
        passed, _ = _run(project, prefix, {
            "vm_name": VM,
            f"{prefix}_backup_provider": provider,
            f"{prefix}_backup_release": "12.1",
            f"{prefix}_backup_hostname": "backup.example.local",
        })
        assert not passed, f"{project} accepted provider {provider!r}"

    def test_an_undeclared_branch_blocks_and_lists_the_known_ones(self, project, prefix):
        passed, output = _run(project, prefix, {
            "vm_name": VM,
            f"{prefix}_backup_provider": "veeam",
            f"{prefix}_backup_release": "99.9.9",
            f"{prefix}_backup_hostname": "backup.example.local",
            f"{prefix}_backup_api_contracts": VEEAM_CONTRACT,
        })
        assert not passed, f"{project} accepted an undeclared backup API branch"
        assert "12.1" in output, (
            f"the error should name the branches that are declared:\n{output[-1500:]}"
        )

    def test_the_shipped_contract_blocks_until_filled_in(self, project, prefix):
        """Endpoints ship empty, so the check cannot silently query nothing."""
        passed, output = _run(project, prefix, {
            "vm_name": VM,
            f"{prefix}_backup_provider": "veeam",
            f"{prefix}_backup_release": "12.1.2",
            f"{prefix}_backup_hostname": "backup.example.local",
        })
        assert not passed, f"{project} accepted the shipped, unfilled contract"
        assert "incomplete" in output, output[-1500:]


# --- evaluating a real catalogue -----------------------------------------


@pytest.mark.parametrize("project, prefix", GUARDED, ids=[p for p, _ in GUARDED])
class TestCatalogueEvaluation:
    """What the role concludes from what the backup server actually returns."""

    def test_a_recent_successful_backup_passes(self, project, prefix, backup_server):
        backup_server.serve([
            {"name": VM, "creationTime": _iso(3), "result": "Success"},
            {"name": VM, "creationTime": _iso(27), "result": "Success"},
        ])
        passed, output = _run(project, prefix, _connected(prefix, backup_server.port))
        assert passed, f"a 3h-old successful backup was rejected:\n{output[-2000:]}"
        assert "STATE=verified" in output, output[-2000:]

    def test_no_restore_point_at_all_blocks(self, project, prefix, backup_server):
        backup_server.serve([])
        passed, output = _run(project, prefix, _connected(prefix, backup_server.port))
        assert not passed, (
            f"{project} proceeded for a VM the backup server has never heard of"
        )
        assert "no successful restore point" in output, output[-2000:]

    def test_only_failed_restore_points_block(self, project, prefix, backup_server):
        """A failed job still leaves a record; it is not a usable backup."""
        backup_server.serve([
            {"name": VM, "creationTime": _iso(2), "result": "Failed"},
            {"name": VM, "creationTime": _iso(26), "result": "Failed"},
        ])
        passed, output = _run(project, prefix, _connected(prefix, backup_server.port))
        assert not passed, (
            f"{project} treated a failed backup job as protection"
        )
        assert "no successful restore point" in output, output[-2000:]

    def test_another_vms_backup_does_not_count(self, project, prefix, backup_server):
        """The endpoint may return the whole catalogue; filtering is on us."""
        backup_server.serve([
            {"name": "SOMEOTHERVM", "creationTime": _iso(1), "result": "Success"},
        ])
        passed, output = _run(project, prefix, _connected(prefix, backup_server.port))
        assert not passed, (
            f"{project} accepted a different VM's restore point as this VM's "
            f"backup - the deletion would have gone ahead"
        )

    def test_a_stale_backup_blocks(self, project, prefix, backup_server):
        backup_server.serve([
            {"name": VM, "creationTime": _iso(72), "result": "Success"},
        ])
        passed, output = _run(project, prefix, _connected(prefix, backup_server.port))
        assert not passed, f"{project} accepted a 72h-old backup against a 24h limit"
        assert "past the" in output, output[-2000:]

    def test_a_stale_backup_passes_when_the_limit_is_raised(self, project, prefix, backup_server):
        backup_server.serve([
            {"name": VM, "creationTime": _iso(72), "result": "Success"},
        ])
        passed, output = _run(project, prefix, _connected(
            prefix, backup_server.port, **{f"{prefix}_backup_max_age_hours": 168}))
        assert passed, (
            f"a 72h-old backup was rejected against a deliberately raised 168h "
            f"limit:\n{output[-2000:]}"
        )

    def test_the_newest_point_decides_not_the_first_returned(self, project, prefix, backup_server):
        """Catalogues are not sorted; taking the first would be luck."""
        backup_server.serve([
            {"name": VM, "creationTime": _iso(200), "result": "Success"},
            {"name": VM, "creationTime": _iso(2), "result": "Success"},
            {"name": VM, "creationTime": _iso(100), "result": "Success"},
        ])
        passed, output = _run(project, prefix, _connected(prefix, backup_server.port))
        assert passed, (
            f"{project} did not use the newest restore point - an out-of-order "
            f"catalogue made a protected VM look stale:\n{output[-2000:]}"
        )

    def test_a_failed_newer_point_does_not_mask_a_stale_good_one(self, project, prefix, backup_server):
        """Age must be measured on the newest *successful* point."""
        backup_server.serve([
            {"name": VM, "creationTime": _iso(1), "result": "Failed"},
            {"name": VM, "creationTime": _iso(72), "result": "Success"},
        ])
        passed, output = _run(project, prefix, _connected(prefix, backup_server.port))
        assert not passed, (
            f"{project} measured freshness from a *failed* job an hour ago and "
            f"ignored that the last real backup is three days old"
        )


# --- the waiver -----------------------------------------------------------


@pytest.mark.parametrize("project, prefix", GUARDED, ids=[p for p, _ in GUARDED])
class TestWaiver:
    """Overriding must be possible, deliberate, and visible afterwards."""

    def test_a_waiver_lets_a_missing_backup_through(self, project, prefix, backup_server):
        backup_server.serve([])
        passed, output = _run(project, prefix, _connected(
            prefix, backup_server.port, **{f"{prefix}_backup_allow_missing": True}))
        assert passed, f"the waiver did not take effect:\n{output[-2000:]}"
        assert "STATE=waived" in output, (
            f"a waived run must say so in the artifact, not report a clean "
            f"verification:\n{output[-2000:]}"
        )

    def test_a_waiver_lets_a_stale_backup_through_and_says_so(self, project, prefix, backup_server):
        backup_server.serve([
            {"name": VM, "creationTime": _iso(72), "result": "Success"},
        ])
        passed, output = _run(project, prefix, _connected(
            prefix, backup_server.port, **{f"{prefix}_backup_allow_missing": True}))
        assert passed, output[-2000:]
        assert "STATE=stale-waived" in output, (
            f"a stale-but-waived run must be distinguishable from a verified "
            f"one:\n{output[-2000:]}"
        )

    def test_a_waiver_does_not_downgrade_a_genuine_pass(self, project, prefix, backup_server):
        """With a good backup, the waiver must not relabel the outcome."""
        backup_server.serve([
            {"name": VM, "creationTime": _iso(2), "result": "Success"},
        ])
        passed, output = _run(project, prefix, _connected(
            prefix, backup_server.port, **{f"{prefix}_backup_allow_missing": True}))
        assert passed, output[-2000:]
        assert "STATE=verified" in output, (
            f"a run with a good backup was labelled as waived:\n{output[-2000:]}"
        )


# --- wiring ---------------------------------------------------------------


@pytest.mark.parametrize("project, prefix", GUARDED, ids=[p for p, _ in GUARDED])
def test_the_destructive_playbook_runs_the_check(project, prefix):
    """The role has to be wired in ahead of the irreversible step."""
    from conftest import load_yaml, walk_tasks

    # Named explicitly rather than matched on a prefix: `delete_vm_lock` and
    # `upgrade_lock` share the prefix of the roles that actually destroy
    # something, and a lock legitimately runs before the check.
    playbook_name, irreversible = {
        "ansible-deletevm": (
            "delete_vm.yml",
            {"delete_vm_vmware", "delete_vm_scvmm", "delete_vm_hyperv"},
        ),
        "ansible-inplace-upgrade": (
            "inplace_upgrade.yml",
            {"upgrade_windows", "upgrade_redhat"},
        ),
    }[project]
    playbook = REPO_ROOT / project / "playbooks" / playbook_name
    roles = []
    for play in load_yaml(playbook) or []:
        for task in walk_tasks(play.get("tasks")):
            include = task.get("ansible.builtin.include_role")
            if isinstance(include, dict) and isinstance(include.get("name"), str):
                roles.append(include["name"])

    assert "preflight_backup" in roles, (
        f"{playbook.name} does not run preflight_backup at all"
    )
    check = roles.index("preflight_backup")
    acting = [i for i, name in enumerate(roles) if name in irreversible]
    assert acting, (
        f"none of {sorted(irreversible)} is included by {playbook.name}; roles "
        f"found: {roles}"
    )
    assert check < min(acting), (
        f"{playbook.name} runs preflight_backup after {roles[min(acting)]} - "
        f"the check must precede the irreversible step, not follow it"
    )

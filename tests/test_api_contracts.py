"""Release-aware REST contract resolution for the appliance projects.

The Quantum DXi and HPE StoreOnce appliances expose different REST paths,
methods and features depending on the software branch they run. Both
projects therefore take the release as a variable and resolve it against a
per-branch contract table, rather than hardcoding one branch's paths.

That resolution is ordinary Ansible variable logic, invisible to
`--syntax-check`: a contract table that silently resolves to the wrong
branch, or an override that stops winning, would reconfigure a production
appliance through the wrong endpoints. These tests run the real
`api_contract` and `preflight` roles through `ansible-playbook`.
"""
from __future__ import annotations

import json
import os
import pathlib
import subprocess
import tempfile

import pytest
import yaml

from conftest import REPO_ROOT, load_yaml

# (appliance, variable prefix) - the two projects are the same mechanism with a
# different prefix, so every test runs against both.
APPLIANCES = [
    ("ansible-hpe-storeonce-conf", "storeonce"),
    ("ansible-quantum-dxi-conf", "dxi"),
]

SETTINGS = ["local_accounts", "ad", "ntp", "timezone", "syslog", "smtp", "snmp"]


def _contract(snmp_v3: bool = True, **endpoint_overrides) -> dict:
    endpoints = {name: f"/api/v1/{name}" for name in SETTINGS}
    endpoints.update(endpoint_overrides)
    return {
        "endpoints": endpoints,
        "methods": {name: ("POST" if name == "local_accounts" else "PUT") for name in SETTINGS},
        "capabilities": {"snmp_v3": snmp_v3},
    }


def _run(appliance: str, prefix: str, extra_vars: dict, roles: list[str]) -> tuple[bool, str]:
    """Run the named roles of a appliance with the given variables."""
    appliance_dir = REPO_ROOT / appliance
    play = [{
        "name": "contract",
        "hosts": "localhost",
        "connection": "local",
        "gather_facts": False,
        "tasks": (
            [{"name": f"include {role}", "ansible.builtin.include_role": {"name": role}}
             for role in roles]
            + [{
                "name": "report",
                "ansible.builtin.debug": {
                    "msg": {
                        "branch": f"{{{{ {prefix}_release_branch }}}}",
                        "endpoints": f"{{{{ {prefix}_endpoints }}}}",
                        "methods": f"{{{{ {prefix}_methods }}}}",
                        "capabilities": f"{{{{ {prefix}_capabilities }}}}",
                    }
                },
            }]
        ),
    }]
    # Vault-sourced names the inventory references but a test never supplies.
    variables = {
        f"vault_{prefix}_api_username": "u",
        f"vault_{prefix}_api_password": "p",
        f"vault_{prefix}_local_admin_password": "x",
        f"vault_{prefix}_ad_username": "a",
        f"vault_{prefix}_ad_password": "b",
    }
    variables.update(extra_vars)

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = pathlib.Path(tmp)
        playbook = tmp_path / "contract.yml"
        playbook.write_text(yaml.safe_dump(play, default_flow_style=False))
        extra = tmp_path / "vars.json"
        extra.write_text(json.dumps(variables))
        inventory = tmp_path / "hosts.yml"
        inventory.write_text((appliance_dir / "inventory" / "hosts.yml.example").read_text())
        # group_vars must sit beside the inventory file to be picked up.
        group_vars = tmp_path / "group_vars"
        group_vars.mkdir()
        (group_vars / "all.yml").write_text(
            (appliance_dir / "inventory" / "group_vars" / "all.yml").read_text()
        )
        result = subprocess.run(
            ["ansible-playbook", str(playbook), "-i", str(inventory), "-e", f"@{extra}"],
            capture_output=True, text=True, cwd=appliance_dir,
            env=dict(os.environ, ANSIBLE_LOCALHOST_WARNING="0",
                     ANSIBLE_INVENTORY_UNPARSED_WARNING="0"),
        )
    return result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize("appliance, prefix", APPLIANCES, ids=[p for p, _ in APPLIANCES])
class TestContractResolution:
    """The api_contract role alone - selection, override, capabilities."""

    def test_release_is_mandatory(self, appliance, prefix):
        passed, output = _run(appliance, prefix, {}, ["api_contract"])
        assert not passed, (
            f"{appliance} resolved a contract with no {prefix}_release supplied - "
            f"there is no safe default branch:\n{output[-1500:]}"
        )

    @pytest.mark.parametrize("release", ["abc", "4", "", "4.x.1", "../etc"])
    def test_malformed_release_is_rejected(self, appliance, prefix, release):
        passed, _ = _run(appliance, prefix, {f"{prefix}_release": release}, ["api_contract"])
        assert not passed, f"{appliance} accepted a malformed release {release!r}"

    def test_unknown_branch_names_the_known_ones(self, appliance, prefix):
        """Falling back to a neighbouring branch is the failure to avoid."""
        passed, output = _run(
            appliance, prefix,
            {f"{prefix}_release": "99.99.1", f"{prefix}_api_contracts": {"4.3": _contract()}},
            ["api_contract"],
        )
        assert not passed, f"{appliance} accepted an undeclared branch"
        assert "Known branches: 4.3" in output, (
            f"the error should list the declared branches so the operator knows "
            f"what to add:\n{output[-1500:]}"
        )

    def test_patch_level_does_not_affect_selection(self, appliance, prefix):
        """major.minor selects; the patch level only rides along in the artifact."""
        branches = {}
        for release in ("4.3.0", "4.3.7", "4.3.12-hotfix"):
            passed, output = _run(
                appliance, prefix,
                {f"{prefix}_release": release, f"{prefix}_api_contracts": {"4.3": _contract()}},
                ["api_contract"],
            )
            assert passed, f"{release} failed to resolve:\n{output[-1500:]}"
            branches[release] = "4.3" in output
        assert all(branches.values()), f"{appliance} did not map every patch level to 4.3"

    def test_the_right_branch_is_selected(self, appliance, prefix):
        contracts = {
            "3.18": _contract(snmp_v3=False, ntp="/old/ntp"),
            "4.3": _contract(snmp_v3=True, ntp="/new/ntp"),
        }
        for release, expected_path, expected_v3 in [
            ("3.18.4", "/old/ntp", "False"),
            ("4.3.2", "/new/ntp", "True"),
        ]:
            passed, output = _run(
                appliance, prefix,
                {f"{prefix}_release": release, f"{prefix}_api_contracts": contracts},
                ["api_contract"],
            )
            assert passed, output[-1500:]
            assert expected_path in output, (
                f"{appliance} on {release} did not resolve ntp to {expected_path} - "
                f"it may have selected the other branch:\n{output[-1500:]}"
            )
            assert f"'snmp_v3': {expected_v3}" in output or f'"snmp_v3": {expected_v3.lower()}' in output, (
                f"{appliance} on {release} resolved the wrong snmp_v3 capability:\n{output[-1500:]}"
            )

    @pytest.mark.parametrize("setting", SETTINGS)
    def test_per_appliance_endpoint_override_wins(self, appliance, prefix, setting):
        """Pinning one path must not require forking the whole table.

        This is also what keeps inventories written against the previous
        flat-variable form working unchanged.
        """
        passed, output = _run(
            appliance, prefix,
            {
                f"{prefix}_release": "4.3.2",
                f"{prefix}_api_contracts": {"4.3": _contract()},
                f"{prefix}_{setting}_endpoint": "/pinned/path",
            },
            ["api_contract"],
        )
        assert passed, output[-1500:]
        assert "/pinned/path" in output, (
            f"{appliance}: the {setting} override did not win over the contract:\n"
            f"{output[-1500:]}"
        )

    def test_empty_override_does_not_blank_the_contract(self, appliance, prefix):
        """An unset override must fall through, not erase a working path."""
        passed, output = _run(
            appliance, prefix,
            {
                f"{prefix}_release": "4.3.2",
                f"{prefix}_api_contracts": {"4.3": _contract(ntp="/from/contract")},
                f"{prefix}_ntp_endpoint": "",
            },
            ["api_contract"],
        )
        assert passed, output[-1500:]
        assert "/from/contract" in output, (
            f"{appliance}: an empty override blanked the contract's own path:\n"
            f"{output[-1500:]}"
        )


@pytest.mark.parametrize("appliance, prefix", APPLIANCES, ids=[p for p, _ in APPLIANCES])
class TestContractPreflight:
    """api_contract + preflight - what the resolved contract is checked against."""

    def _base(self, prefix, contract=None, **extra):
        variables = {
            f"{prefix}_release": "4.3.2",
            f"{prefix}_api_contracts": {"4.3": contract or _contract()},
        }
        variables.update(extra)
        return variables

    def test_a_complete_contract_passes(self, appliance, prefix):
        passed, output = _run(
            appliance, prefix, self._base(prefix), ["api_contract", "preflight"]
        )
        assert passed, f"a fully declared contract was rejected:\n{output[-2000:]}"

    def test_the_shipped_table_blocks_until_filled_in(self, appliance, prefix):
        """Shipping empty paths must fail loudly, never send a request to '/'.

        Uses a branch the project actually declares, so this exercises the
        shipped table rather than the unknown-branch path.
        """
        shipped = load_yaml(
            REPO_ROOT / appliance / "inventory" / "group_vars" / "all.yml"
        )[f"{prefix}_api_contracts"]
        branch = sorted(shipped)[0]
        passed, output = _run(
            appliance, prefix, {f"{prefix}_release": f"{branch}.0"},
            ["api_contract", "preflight"],
        )
        assert not passed, (
            f"{appliance} passed preflight with the shipped, unfilled contract "
            f"for branch {branch} - it would issue requests against empty paths"
        )
        assert "No usable API path" in output, output[-2000:]

    @pytest.mark.parametrize("setting", ["local_accounts", "ad", "ntp", "timezone"])
    def test_a_missing_mandatory_path_is_named(self, appliance, prefix, setting):
        contract = _contract()
        contract["endpoints"][setting] = ""
        passed, output = _run(
            appliance, prefix, self._base(prefix, contract), ["api_contract", "preflight"]
        )
        assert not passed, f"{appliance} accepted an empty {setting} path"
        assert setting in output, (
            f"the error does not name {setting}, so the operator cannot tell "
            f"which path to fill in:\n{output[-2000:]}"
        )

    @pytest.mark.parametrize("setting", ["syslog", "smtp", "snmp"])
    def test_optional_settings_only_need_a_path_when_enabled(self, appliance, prefix, setting):
        contract = _contract()
        contract["endpoints"][setting] = ""

        passed, output = _run(
            appliance, prefix, self._base(prefix, contract), ["api_contract", "preflight"]
        )
        assert passed, (
            f"{appliance}: a missing {setting} path blocked the run even though "
            f"{setting} is disabled:\n{output[-2000:]}"
        )

        enabled = self._base(prefix, contract, **{f"{prefix}_{setting}_enabled": True})
        passed, output = _run(appliance, prefix, enabled, ["api_contract", "preflight"])
        assert not passed, (
            f"{appliance}: {setting} was enabled with no path and preflight let it through"
        )

    def test_snmpv3_is_refused_on_a_branch_without_it(self, appliance, prefix):
        """The appliance would silently downgrade to a community string."""
        variables = self._base(
            prefix, _contract(snmp_v3=False), **{f"{prefix}_snmp_enabled": True}
        )
        passed, output = _run(appliance, prefix, variables, ["api_contract", "preflight"])
        assert not passed, (
            f"{appliance} accepted an SNMPv3 request on a branch declared without "
            f"v3 support"
        )
        assert "snmp_v3" in output or "SNMPv3" in output, output[-2000:]

    def test_snmpv3_is_allowed_on_a_branch_with_it(self, appliance, prefix):
        variables = self._base(
            prefix, _contract(snmp_v3=True), **{f"{prefix}_snmp_enabled": True}
        )
        passed, output = _run(appliance, prefix, variables, ["api_contract", "preflight"])
        assert passed, f"SNMPv3 was refused on a branch that declares it:\n{output[-2000:]}"

    @pytest.mark.parametrize("method", ["GET", "HEAD", "DELETE"])
    def test_a_non_writing_method_is_refused(self, appliance, prefix, method):
        """A read-only verb cannot apply a configuration, and would look fine."""
        variables = self._base(prefix, **{f"{prefix}_ntp_method": method})
        passed, output = _run(appliance, prefix, variables, ["api_contract", "preflight"])
        assert not passed, (
            f"{appliance} accepted {method!r} as the NTP request method - the run "
            f"would report success without changing anything"
        )

    def test_a_contract_with_no_method_is_refused(self, appliance, prefix):
        """An empty method in the table itself must not reach the uri module.

        This is distinct from an empty *override*, which correctly means
        "use the contract's method" and is covered above.
        """
        contract = _contract()
        contract["methods"]["ntp"] = ""
        passed, output = _run(
            appliance, prefix, self._base(prefix, contract), ["api_contract", "preflight"]
        )
        assert not passed, (
            f"{appliance} accepted a contract declaring no method for ntp"
        )


# --- the shipped inventory ------------------------------------------------


@pytest.mark.parametrize("appliance, prefix", APPLIANCES, ids=[p for p, _ in APPLIANCES])
def test_shipped_contract_table_is_well_formed(appliance, prefix):
    """Every declared branch must carry the full set of keys.

    A branch missing one endpoint key resolves to an undefined lookup rather
    than to a clear preflight failure.
    """
    group_vars = load_yaml(
        REPO_ROOT / appliance / "inventory" / "group_vars" / "all.yml"
    )
    contracts = group_vars[f"{prefix}_api_contracts"]
    assert contracts, f"{appliance} declares no branches at all"
    for branch, contract in contracts.items():
        assert set(contract["endpoints"]) == set(SETTINGS), (
            f"{appliance} branch {branch} does not declare every endpoint: "
            f"{sorted(contract['endpoints'])}"
        )
        assert set(contract["methods"]) == set(SETTINGS), (
            f"{appliance} branch {branch} does not declare every method: "
            f"{sorted(contract['methods'])}"
        )
        for setting, method in contract["methods"].items():
            assert method in ("POST", "PUT", "PATCH"), (
                f"{appliance} branch {branch} uses {method!r} for {setting}"
            )


@pytest.mark.parametrize("appliance, prefix", APPLIANCES, ids=[p for p, _ in APPLIANCES])
def test_no_role_still_reads_the_flat_endpoint_variables(appliance, prefix):
    """The acting roles must go through the resolved contract.

    A role left reading `<prefix>_ntp_endpoint` directly would ignore the
    release entirely and silently use the override-or-nothing path.
    """
    offenders = []
    for path in (REPO_ROOT / appliance / "roles").glob("*/tasks/*.yml"):
        if path.parent.parent.name in ("api_contract", "preflight"):
            continue
        text = path.read_text()
        for setting in SETTINGS:
            for suffix in ("endpoint", "method"):
                if f"{prefix}_{setting}_{suffix} }}" in text:
                    offenders.append(f"{path.parent.parent.name}: {prefix}_{setting}_{suffix}")
    assert not offenders, (
        f"{appliance} role(s) bypass the resolved contract: {offenders} - they "
        f"would ignore {prefix}_release"
    )

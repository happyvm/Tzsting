"""The embedded-script extractors must find every script CI claims to scan.

Six projects embed PowerShell (and one embeds bash) as Jinja-templated YAML
string literals. PSScriptAnalyzer and ShellCheck cannot read those, so
`scripts/extract_embedded_scripts.py` writes them out as standalone files
and the PowerShell Quality workflow analyses the result.

That makes the extractor a silent single point of failure: if it misses a
script, the workflow still goes green - it just analyses less than it
appears to. `ansible-inplace-upgrade` shipped a copy of
`ansible-resizedisk`'s extractor that only knew about
`ansible.windows.win_shell`, so the four `win_powershell` scripts in that
project - including the one that actually runs Windows setup.exe - were
never scanned. These tests compare what each extractor produces against
the scripts genuinely present in the YAML, so that cannot recur silently.
"""
from __future__ import annotations

import re
import subprocess
import sys

import pytest

from conftest import PROJECTS, module_of, tasks_in_file

POWERSHELL_MODULES = {
    "ansible.windows.win_shell",
    "ansible.windows.win_powershell",
}
BASH_MODULES = {"ansible.builtin.shell"}

EXTRACTOR_PROJECTS = [
    p for p in PROJECTS if (p.path / "scripts" / "extract_embedded_scripts.py").is_file()
]


JINJA_EXPR_RE = re.compile(r"\{\{.*?\}\}")
JINJA_TAG_RE = re.compile(r"[ \t]*\{%-?.*?-?%\}[ \t]*\n?")


JINJA_PLACEHOLDER = "12345"


def _as_extracted(body: str) -> str:
    """The form a script body takes once an extractor has written it out.

    Every extractor here performs the same two substitutions - `{{ expr }}`
    becomes a numeric placeholder so the result still parses, and `{% tag %}`
    control flow is dropped - so reproducing them lets an expected body be
    compared against the file on disk. Whitespace is ignored to stay
    indifferent to how the YAML block scalar was indented.
    """
    body = JINJA_TAG_RE.sub("", body)
    body = JINJA_EXPR_RE.sub(JINJA_PLACEHOLDER, body)
    return _collapse(body)


def _collapse(text: str) -> str:
    return "".join(text.split())


def _normalise(text: str) -> str:
    """A body stripped of Jinja entirely, to spot pure-passthrough scripts."""
    return _collapse(JINJA_EXPR_RE.sub("", JINJA_TAG_RE.sub("", text)))


def _script_bodies(project, modules) -> list[tuple[str, str]]:
    """The (where, body) of every script a task in `modules` executes.

    A body that is nothing but Jinja - `run_guest_command`'s `{{ script }}`
    passthrough, which receives its content from the calling role - carries
    no analysable code of its own and is skipped.
    """
    bodies = []
    for path in project.task_files() + project.playbooks():
        for task in tasks_in_file(path):
            module = module_of(task)
            if module not in modules:
                continue
            value = task[module]
            if isinstance(value, dict):
                value = value.get("cmd") or value.get("script")
            if not isinstance(value, str) or not _normalise(value):
                continue
            bodies.append((f"{path.relative_to(project.path)}: {task.get('name', '?')}", value))
    return bodies


def _run_extractor(project, mode, out_dir) -> int:
    script = project.path / "scripts" / "extract_embedded_scripts.py"
    result = subprocess.run(
        [sys.executable, str(script), mode, str(out_dir)],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, (
        f"{project.name} extractor failed in {mode} mode:\n{result.stderr}"
    )
    return result.returncode


@pytest.fixture(params=EXTRACTOR_PROJECTS, ids=[p.name for p in EXTRACTOR_PROJECTS])
def extractor_project(request):
    return request.param


def test_extractor_covers_every_powershell_script(extractor_project, tmp_path):
    """Every embedded PowerShell block must reach a file the analyser will read.

    Matching on content rather than on a count means a project can extract
    extra material (a helper role's `vars: script:`, say) without weakening
    the check that nothing is *missing*.
    """
    project = extractor_project
    _run_extractor(project, "powershell", tmp_path)
    extracted = {
        _collapse(path.read_text())
        for path in (tmp_path / "powershell").glob("*.ps1")
    }
    missed = [
        where for where, body in _script_bodies(project, POWERSHELL_MODULES)
        if _as_extracted(body) not in extracted
    ]
    assert not missed, (
        f"{project.name}: the extractor never wrote out {missed} - "
        f"PSScriptAnalyzer only sees what was written, so CI would stay green "
        f"while silently not analysing these"
    )


def test_extracted_powershell_is_not_empty(extractor_project, tmp_path):
    project = extractor_project
    _run_extractor(project, "powershell", tmp_path)
    for path in sorted((tmp_path / "powershell").glob("*.ps1")):
        assert path.read_text().strip(), f"{project.name}: {path.name} is empty"


def test_extracted_powershell_has_no_jinja_left(extractor_project, tmp_path):
    """Leftover Jinja would make PSScriptAnalyzer fail to parse the file."""
    project = extractor_project
    _run_extractor(project, "powershell", tmp_path)
    for path in sorted((tmp_path / "powershell").glob("*.ps1")):
        text = path.read_text()
        assert "{{" not in text and "{%" not in text, (
            f"{project.name}: {path.name} still contains Jinja after extraction"
        )


def test_extractor_rejects_an_unknown_mode(extractor_project, tmp_path):
    """A typo'd mode must fail loudly, not silently extract nothing."""
    script = extractor_project.path / "scripts" / "extract_embedded_scripts.py"
    result = subprocess.run(
        [sys.executable, str(script), "powershel", str(tmp_path)],
        capture_output=True, text=True,
    )
    assert result.returncode != 0, (
        f"{extractor_project.name} extractor accepted an unknown mode instead "
        f"of failing - a typo in the workflow would extract nothing and still "
        f"let the analysis step pass"
    )


def test_analyzer_settings_do_not_cite_foreign_roles(extractor_project):
    """A settings file must justify its suppressions against its own roles.

    These files are copied between the sibling projects along with the
    extractor, and a copied comment that cites roles the project does not
    have is how a suppression outlives the reason for it -
    ansible-inplace-upgrade carried ansible-resizedisk's two exclusions,
    justified by `run_guest_command` and `resize_disk_scvmm`, neither of
    which exists there.
    """
    settings = extractor_project.path / "scripts" / "PSScriptAnalyzerSettings.psd1"
    if not settings.is_file():
        pytest.skip("no analyzer settings for this project")
    own_roles = {r.name for r in extractor_project.roles()}
    all_roles = {r.name for p in PROJECTS for r in p.roles()}
    text = settings.read_text()
    foreign = sorted(
        role for role in all_roles - own_roles
        if re.search(rf"\b{re.escape(role)}\b", text)
    )
    assert not foreign, (
        f"{extractor_project.name}/scripts/PSScriptAnalyzerSettings.psd1 "
        f"justifies its suppressions with role(s) {foreign} that belong to "
        f"another project - the comment was copied along with the rules"
    )


BASH_EXTRACTORS = [
    p for p in EXTRACTOR_PROJECTS
    if "extract_bash" in (p.path / "scripts" / "extract_embedded_scripts.py").read_text()
]


@pytest.mark.parametrize(
    "bash_project", BASH_EXTRACTORS, ids=[p.name for p in BASH_EXTRACTORS]
)
def test_bash_extractor_produces_something(bash_project, tmp_path):
    """A bash mode that silently yields nothing is worse than no bash mode.

    ansible-inplace-upgrade shipped one that filtered on two role names
    copied from ansible-resizedisk and absent from itself, so it always
    wrote zero files - and ShellCheck on an empty directory passes.
    """
    _run_extractor(bash_project, "bash", tmp_path)
    produced = sorted((tmp_path / "bash").glob("*.sh"))
    assert produced, (
        f"{bash_project.name} offers a bash extraction mode but produced no "
        f"files - ShellCheck would then pass by having nothing to check"
    )
    for path in produced:
        assert path.read_text().strip(), f"{bash_project.name}: {path.name} is empty"

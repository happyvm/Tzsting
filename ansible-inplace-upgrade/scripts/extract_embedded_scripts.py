#!/usr/bin/env python3
"""Extract embedded PowerShell/bash scripts from the playbook and role task
YAML files into standalone files, for static analysis (PSScriptAnalyzer,
ShellCheck) that can't parse YAML-embedded, Jinja-templated script blocks
directly.

Jinja {{ ... }} placeholders are replaced with a plain numeric literal
(12345) so the extracted files stay syntactically valid: every {{ }} in
these scripts is either inside a quoted string (a number substitutes in
cleanly) or used as a bare numeric literal - never as a bare identifier,
keyword, or cmdlet name. Jinja {% ... %} control tags are stripped
entirely, which flattens every branch into the output unconditionally:
syntactically valid, and a deliberate superset of what any single real
run would render.

This project reaches its guests through more than one module, so all of
them have to be collected: `ansible.windows.win_shell` (free-form or
`cmd:`) and `ansible.windows.win_powershell` (`script:`) for PowerShell,
`ansible.builtin.shell` for bash. Scripts also live inside `block:` /
`rescue:` / `always:` sections and in the playbook itself (the Hyper-V
rollback checkpoint), not only at the top level of a role's
tasks/main.yml - so the walk recurses and covers playbooks/ as well as
roles/.

Usage: extract_embedded_scripts.py [all|powershell|bash] [output_dir]
"""
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
JINJA_RE = re.compile(r"\{\{.*?\}\}")
JINJA_BLOCK_RE = re.compile(r"[ \t]*\{%-?.*?-?%\}[ \t]*\n?")

# Module name -> the key holding the script when the task uses the
# explicit keyword-argument form rather than the free-form one.
POWERSHELL_MODULES = {
    "ansible.windows.win_shell": "cmd",
    "win_shell": "cmd",
    "ansible.windows.win_powershell": "script",
    "win_powershell": "script",
}
BASH_MODULES = {
    "ansible.builtin.shell": "cmd",
    "shell": "cmd",
}


def substitute(text):
    return JINJA_RE.sub("12345", JINJA_BLOCK_RE.sub("", text))


def iter_task_files():
    """Every YAML file that can hold tasks: role task files and playbooks."""
    yield from sorted((ROOT / "roles").glob("*/tasks/*.yml"))
    yield from sorted((ROOT / "playbooks").glob("*.yml"))


def walk_tasks(node):
    """Yield every task in a task list, recursing into block/rescue/always."""
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


def iter_tasks(tasks_file):
    """Yield every task in a role task file or a playbook."""
    with open(tasks_file) as f:
        docs = yaml.safe_load(f)
    if not isinstance(docs, list):
        return
    if tasks_file.parent.name == "playbooks":
        for play in docs:
            if not isinstance(play, dict):
                continue
            for section in ("pre_tasks", "tasks", "post_tasks", "handlers"):
                yield from walk_tasks(play.get(section))
    else:
        yield from walk_tasks(docs)


def script_for(task, modules):
    """Return the script body a task hands to one of `modules`, if any.

    Covers the free-form (`win_shell: |`), keyword-argument
    (`win_shell: {cmd: ...}`, `win_powershell: {script: ...}`) and
    `vars: {script: ...}` forms.
    """
    for module, key in modules.items():
        if module not in task:
            continue
        value = task[module]
        if isinstance(value, dict):
            value = value.get(key)
        if isinstance(value, str):
            return value
        var_script = (task.get("vars") or {}).get("script")
        if isinstance(var_script, str):
            return var_script
    return None


def extract(out_dir, modules, suffix):
    out_dir.mkdir(parents=True, exist_ok=True)
    count = 0
    for tasks_file in iter_task_files():
        if tasks_file.parent.name == "playbooks":
            origin = f"playbook_{tasks_file.stem}"
        else:
            origin = tasks_file.parent.parent.name
        for task in iter_tasks(tasks_file):
            script = script_for(task, modules)
            if script is None:
                continue
            count += 1
            (out_dir / f"{origin}_{count:02d}.{suffix}").write_text(substitute(script))
    return count


def extract_powershell(out_dir):
    return extract(out_dir, POWERSHELL_MODULES, "ps1")


def extract_bash(out_dir):
    return extract(out_dir, BASH_MODULES, "sh")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    out_base = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / ".extracted"

    if mode not in ("all", "powershell", "bash"):
        raise SystemExit(f"Unknown mode: {mode!r} (expected all, powershell or bash)")

    if mode in ("all", "powershell"):
        n = extract_powershell(out_base / "powershell")
        print(f"Extracted {n} PowerShell script(s) to {out_base / 'powershell'}")

    if mode in ("all", "bash"):
        n = extract_bash(out_base / "bash")
        print(f"Extracted {n} bash script(s) to {out_base / 'bash'}")

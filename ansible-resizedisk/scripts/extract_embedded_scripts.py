#!/usr/bin/env python3
"""Extract embedded PowerShell/bash scripts from the role task YAML files
into standalone files, for static analysis (PSScriptAnalyzer, ShellCheck)
that can't parse YAML-embedded, Jinja-templated script blocks directly.

Jinja {{ ... }} placeholders are replaced with a plain numeric literal
(12345) so the extracted files stay syntactically valid: every {{ }} in
these scripts is either inside a quoted string (a number substitutes in
cleanly) or used as a bare numeric literal - never as a bare identifier,
keyword, or cmdlet name.

Usage: extract_embedded_scripts.py [all|powershell|bash] [output_dir]
"""
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
JINJA_RE = re.compile(r"\{\{.*?\}\}")


def substitute(text):
    return JINJA_RE.sub("12345", text)


def iter_tasks(tasks_file):
    with open(tasks_file) as f:
        docs = yaml.safe_load(f)
    for task in docs or []:
        yield task


def extract_powershell(out_dir):
    out_dir.mkdir(parents=True, exist_ok=True)
    count = 0
    for tasks_file in sorted((ROOT / "roles").glob("*/tasks/main.yml")):
        role = tasks_file.parent.parent.name
        for task in iter_tasks(tasks_file):
            script = task.get("ansible.windows.win_shell")
            # win_shell is used both in free-form ("...") and explicit
            # keyword-argument ({cmd: "..."}) form across this project.
            if isinstance(script, dict):
                script = script.get("cmd")
            if script is None and role == "resize_windows_filesystem":
                script = task.get("vars", {}).get("script")
            if not isinstance(script, str):
                continue
            count += 1
            (out_dir / f"{role}_{count:02d}.ps1").write_text(substitute(script))
    return count


def extract_bash(out_dir):
    out_dir.mkdir(parents=True, exist_ok=True)
    count = 0
    for tasks_file in sorted((ROOT / "roles").glob("*/tasks/main.yml")):
        role = tasks_file.parent.parent.name
        if role != "resize_linux_filesystem":
            continue
        for task in iter_tasks(tasks_file):
            script = task.get("vars", {}).get("script")
            if not isinstance(script, str):
                continue
            count += 1
            (out_dir / f"{role}_{count:02d}.sh").write_text(substitute(script))
    return count


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    out_base = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / ".extracted"

    if mode in ("all", "powershell"):
        n = extract_powershell(out_base / "powershell")
        print(f"Extracted {n} PowerShell script(s) to {out_base / 'powershell'}")

    if mode in ("all", "bash"):
        n = extract_bash(out_base / "bash")
        print(f"Extracted {n} bash script(s) to {out_base / 'bash'}")

#!/usr/bin/env python3
"""Extract embedded PowerShell from the role task YAML files into
standalone files, for static analysis (PSScriptAnalyzer) that can't
parse YAML-embedded, Jinja-templated script blocks directly.

Jinja {{ ... }} placeholders are replaced with a plain numeric literal
(12345) so the extracted files stay syntactically valid: every {{ }} in
these scripts is either inside a quoted string (a number substitutes in
cleanly) or used as a bare numeric literal - never as a bare identifier,
keyword, or cmdlet name.

Unlike ansible-resizedisk, this project has no guest-touching bash (every
operation here is hypervisor-side - VMware Tools/Hyper-V's VSS
integration service handle guest-side consistency on their own, no SSH
into the guest is ever needed), so there's nothing for ShellCheck to
scan and no bash extraction mode.

Usage: extract_embedded_scripts.py [powershell] [output_dir]
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
            if isinstance(script, dict):
                script = script.get("cmd")
            if not isinstance(script, str):
                continue
            count += 1
            (out_dir / f"{role}_{count:02d}.ps1").write_text(substitute(script))
    return count


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "powershell"
    out_base = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / ".extracted"

    if mode == "powershell":
        n = extract_powershell(out_base / "powershell")
        print(f"Extracted {n} PowerShell script(s) to {out_base / 'powershell'}")
    else:
        raise SystemExit(f"Unknown mode: {mode!r} (only 'powershell' is supported)")

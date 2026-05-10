# SOURCE: test_toolbox_smoke.py
# AUTHOR: LORDZURP
# STARDATE: 2026.085
# STATUS: OPERATIONAL
#
# test_toolbox_smoke.py — Smoke tests for Python toolbox scripts
#
# Verify each script is importable/executable and has basic structure.
# Detailed functional tests per-script come later (per-ring process).

import subprocess
import pytest


class TestScriptsExist:
    """All 3 Python toolbox scripts exist and are syntactically valid."""

    @pytest.mark.parametrize("script", [
        "lcars-header.py",
        "apply-headers.py",
        "patch-json.py",
    ])
    def test_syntax_valid(self, toolbox, script):
        """Python can compile the script without SyntaxError."""
        path = toolbox / script
        assert path.exists(), f"{script} not found in {toolbox}"
        result = subprocess.run(
            ["python3", "-m", "py_compile", str(path)],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, f"Syntax error in {script}:\n{result.stderr}"

    @pytest.mark.parametrize("script", [
        "lcars-header.py",
        "apply-headers.py",
        "patch-json.py",
    ])
    def test_help_flag(self, toolbox, script):
        """Script responds to --help without crashing."""
        path = toolbox / script
        result = subprocess.run(
            ["python3", str(path), "--help"],
            capture_output=True, text=True,
            timeout=10,
        )
        # --help should exit 0 (argparse) or 2 (argparse error)
        # Known: patch-json.py has custom arg parsing, no --help (rc=1)
        if script == "patch-json.py":
            pytest.xfail("patch-json.py lacks argparse --help (finding: add argparse)")
        assert result.returncode in (0, 2), \
            f"{script} --help failed (rc={result.returncode}):\n{result.stderr}"

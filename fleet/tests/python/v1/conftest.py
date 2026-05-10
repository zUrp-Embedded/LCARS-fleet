# SOURCE: conftest.py
# AUTHOR: LORDZURP
# STARDATE: 2026.091
# STATUS: OPERATIONAL
#
# conftest.py — pytest configuration for LCARS Python toolbox tests
#
# Provides fixtures for all Python test files.
# Scripts under test: fleet/toolbox/*.py

import os
import sys
import pytest
from pathlib import Path

import subprocess
REPO_ROOT = Path(subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"],
    cwd=Path(__file__).parent, text=True
).strip())
TOOLBOX = REPO_ROOT / "fleet" / "toolbox"


@pytest.fixture
def repo_root():
    """Path to LCARS repo root."""
    return REPO_ROOT


@pytest.fixture
def toolbox():
    """Path to fleet/toolbox/ directory."""
    return TOOLBOX


@pytest.fixture
def tmp_script(tmp_path):
    """Create a temporary .sh script with a header for testing."""
    script = tmp_path / "test-script.sh"
    script.write_text(
        "#!/bin/bash\n"
        "#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |\n"
        "echo hello\n"
    )
    return script

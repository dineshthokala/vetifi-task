"""
Shared test configuration.

Both the integration suite and the hardening suite exercise the same FastAPI
app against a real database, so the environment has to be set once, here, before
any test module is imported. Previously each module set ADMIN_KEY and
DATABASE_URL at import time, which meant whichever module pytest happened to
import first silently won and the other suite failed with 401s.
"""

import os
import sys
import tempfile
from pathlib import Path

import pytest

# Tests import as `server.app.*`, so the repository root must be on sys.path.
# (This used to live in a root pytest.ini; it moved here so the tests work
# with no root-level config file.) conftest is imported before any test
# module, so inserting here covers every run directory.
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

# A per-run temporary directory, so parallel or repeated runs do not collide and
# nothing is left in the repository.
_TMP = Path(tempfile.mkdtemp(prefix="vetifi-tests-"))

os.environ["DATABASE_URL"] = f"sqlite:///{_TMP / 'vetifi_test.db'}"
os.environ["ADMIN_KEY"] = "test-admin-key-2026"
os.environ.pop("CHAOS", None)


@pytest.fixture(scope="session", autouse=True)
def _cleanup_tmpdir():
    yield
    import shutil

    shutil.rmtree(_TMP, ignore_errors=True)
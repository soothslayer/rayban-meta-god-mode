import pytest

from app import tools


@pytest.fixture(autouse=True)
def fresh_lookups():
    """Each test fetches its own (fake) lookups instead of reusing another test's cached answer."""
    tools._cache.clear()

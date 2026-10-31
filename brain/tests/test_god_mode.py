"""TV control, Claude Code remote, code help and the choice of main brain, all with fakes: no TV, no real
Claude Code run and no API calls are needed."""
import os
import stat
import tempfile
import time

os.environ.setdefault("CJ_HOME", tempfile.mkdtemp())
os.environ["CJ_FORCE_MOCK"] = "1"

import pytest
from fastapi.testclient import TestClient

from app import agent, config, mac, tv
from app.main import app
from app.models.base import Attachment
from app.models.router import Router

client = TestClient(app)
AUTH = {"Authorization": f"Bearer {config.token()}"}


def ask(text):
    r = client.post("/api/ask", json={"text": text}, headers=AUTH)
    assert r.status_code == 200, r.text
    return r.json()["spoken"]


@pytest.fixture(autouse=True)
def no_pending(monkeypatch):
    monkeypatch.setattr(mac, "_pending", None)


# ---- TV ---------------------------------------------------------------------------------------------------

class FakeTV:
    def __init__(self):
        self.commands = []

    def shell(self, command):
        self.commands.append(command)
        if command == "pm list packages":
            return "package:com.netflix.ninja\npackage:com.amazon.firetv.youtube\npackage:com.spotify.tv.android"
        return ""


@pytest.fixture
def fake_tv(monkeypatch):
    fake = FakeTV()
    monkeypatch.setattr(tv, "link", fake)
    return fake


def test_tv_opens_installed_apps_by_name(fake_tv):
    assert ask("tv open netflix") == "Opening Netflix on the TV."
    assert "monkey -p com.netflix.ninja -c android.intent.category.LEANBACK_LAUNCHER 1" in fake_tv.commands


def test_tv_refuses_apps_that_are_not_installed(fake_tv):
    assert "isn't installed" in ask("tv open hotstar")


def test_tv_keys_come_from_a_fixed_list(fake_tv):
    assert ask("tv press play pause") == "Done."
    assert fake_tv.commands[-1] == "input keyevent 85"
    assert "can't press" in ask("tv press reboot")


def test_tv_youtube_search_is_url_encoded(fake_tv):
    tv.ACTIONS["tv_youtube"]({"query": "lofi beats'; rm -rf /"})
    command = fake_tv.commands[-1]
    assert "rm+-rf" in command and "';" not in command.split("-d", 1)[1].split("-p")[0].strip("' ")


def test_tv_without_setup_says_how(monkeypatch):
    monkeypatch.setattr(tv, "link", tv._Link())
    cfg = config.load()
    cfg.pop("tv_host", None)
    config.save(cfg)
    assert "set-tv.sh" in ask("tv open netflix")


# ---- Claude Code remote -------------------------------------------------------------------------------------

@pytest.fixture
def projects(monkeypatch, tmp_path):
    for name in ("portfolio-site", "cj-glasses"):
        (tmp_path / name / ".git").mkdir(parents=True)
    (tmp_path / "not-a-repo").mkdir()
    monkeypatch.setattr(agent, "CODE_DIRS", [str(tmp_path)])
    fake = tmp_path / "claude"
    fake.write_text('#!/bin/sh\necho \'{"result": "Added a dark mode toggle to the header. Tests not run.", "is_error": false}\'\n')
    fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("CJ_CLAUDE_CODE_BIN", str(fake))
    agent.JOBS.clear()
    return tmp_path


def test_claude_code_asks_first_then_runs_and_reports(projects):
    question = ask("ask claude code to add a dark mode toggle in portfolio")
    assert question == "Ask Claude Code to add a dark mode toggle in portfolio-site?"
    assert not agent.JOBS
    assert "on it in portfolio-site" in ask("yes")
    for _ in range(50):
        if all(j.state != "running" for j in agent.JOBS.values()):
            break
        time.sleep(0.1)
    done = client.get("/api/jobs/done", headers=AUTH).json()["jobs"]
    assert done == [{"project": "portfolio-site", "state": "done",
                     "summary": "Added a dark mode toggle to the header. Tests not run."}]
    assert client.get("/api/jobs/done", headers=AUTH).json()["jobs"] == []  # announced once


def test_claude_code_only_works_in_git_projects(projects):
    assert "couldn't find a project" in ask("ask claude code to fix things in not-a-repo")


def test_claude_code_may_not_run_shell_commands():
    assert "Bash(git status)" in agent.ALLOWED_TOOLS
    assert "Bash " not in agent.ALLOWED_TOOLS + " " and "Bash(*" not in agent.ALLOWED_TOOLS


# ---- Code help ----------------------------------------------------------------------------------------------

def test_code_help_reads_the_screen(monkeypatch):
    monkeypatch.setattr(mac, "screenshot", lambda: "aGVsbG8=")
    ran = []
    monkeypatch.setattr(mac, "_run", lambda args: ran.append(args) or "")
    assert ask("help with this code")
    assert ran == []  # looking at the screen runs nothing


# ---- Main brain choice --------------------------------------------------------------------------------------

def test_claude_can_be_the_main_brain_but_speech_stays_on_gemini(monkeypatch):
    monkeypatch.delenv("CJ_FORCE_MOCK")
    r = Router()
    for p in r.providers.values():
        monkeypatch.setattr(p.__class__, "available", lambda self: True)
    monkeypatch.setenv("CJ_PROVIDER", "claude")
    assert [p.name for p in r.chain()] == ["claude", "gemini", "groq"]
    assert [p.name for p in r.chain(Attachment("x", "image/jpeg"))] == ["claude", "gemini"]
    assert [p.name for p in r.chain(Attachment("x", "audio/wav"))] == ["gemini"]


def test_unavailable_main_brain_falls_back_to_gemini(monkeypatch):
    r = Router()
    monkeypatch.setenv("CJ_PROVIDER", "openai")
    monkeypatch.setattr(r.providers["openai"].__class__, "available", lambda self: False)
    assert r.preferred() == "gemini"


def test_device_actions_filed_under_tool_still_run(fake_tv, monkeypatch):
    from app.modes import assistant
    data = assistant._normalise({"spoken": "Opening Netflix.", "mac_action": None,
                                 "tool": {"name": "tv_open", "args": {"app": "netflix"}}})
    assert data["mac_action"]["name"] == "tv_open" and data["tool"] is None
    data = assistant._normalise({"mac_action": {"name": "weather", "args": {"place": "Pune"}}, "tool": None})
    assert data["tool"]["name"] == "weather"

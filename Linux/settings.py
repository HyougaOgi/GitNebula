"""User preferences and Secret Service credentials; never persist a passphrase in JSON."""

import contextlib
import json
import locale
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile


class Settings:
    def __init__(self):
        self.path = Path(
            os.environ.get(
                "GITNEBULA_SETTINGS_PATH",
                str(
                    Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
                    / "gitnebula/settings.json"
                ),
            )
        )
        self.values = dict(
            theme="system",
            language="ja" if (locale.getlocale()[0] or "").startswith("ja") else "en",
            transparency=0.0,
            show_home=False,
            keep_running=True,
            ssh_key="",
            git_executable="",
            graph_mode="normal",
        )
        try:
            self.values.update(json.loads(self.path.read_text()))
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        if self.values["language"] not in ("ja", "en"):
            self.values["language"] = "en"

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(dir=self.path.parent)
        try:
            with os.fdopen(descriptor, "w") as stream:
                json.dump(self.values, stream, ensure_ascii=False)
            os.replace(temporary, self.path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def text(self, text):
        if self.values["language"] == "ja":
            return text
        return translations().get(text, text)

    @property
    def autostart_path(self):
        return (
            Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
            / "autostart/dev.gitnebula.desktop"
        )

    def set_autostart(self, enabled):
        target = self.autostart_path
        if not enabled:
            target.unlink(missing_ok=True)
            return

        def quote(value):
            escaped = (
                str(value)
                .replace("\\", "\\\\")
                .replace('"', '\\"')
                .replace("`", "\\`")
                .replace("$", "\\$")
                .replace("%", "%%")
            )
            return '"' + escaped + '"'

        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(
            "[Desktop Entry]\nType=Application\nName=GitNebula\nExec="
            + quote(sys.executable)
            + " "
            + quote(Path(__file__).with_name("main.py").resolve())
            + "\nX-GNOME-Autostart-enabled=true\n"
        )


_translations = None


def translations():
    global _translations
    if _translations is None:
        candidates = [
            Path(__file__).with_name("en.json"),
            Path(__file__).parents[1] / "Mac/Sources/GitNebula/Resources/en.json",
        ]
        _translations = next(
            (json.loads(p.read_text()) for p in candidates if p.exists()), {}
        )
    return _translations


class SecretStore:
    @staticmethod
    def command():
        tool = shutil.which("secret-tool")
        if tool is None:
            raise RuntimeError(
                "SSH パスフレーズの保存には libsecret-tools と Secret Service が必要です。"
            )
        return tool

    @classmethod
    def read(cls, key):
        result = subprocess.run(
            [
                cls.command(),
                "lookup",
                "application",
                "dev.gitnebula.desktop",
                "key",
                str(Path(key).expanduser().absolute()),
            ],
            capture_output=True,
        )
        if result.returncode not in (0, 1):
            raise RuntimeError("保存した SSH パスフレーズを読み込めません。")
        return (
            result.stdout.decode().removesuffix("\n")
            if result.returncode == 0
            else None
        )

    @classmethod
    def save(cls, key, value):
        result = subprocess.run(
            [
                cls.command(),
                "store",
                "--label=GitNebula SSH",
                "application",
                "dev.gitnebula.desktop",
                "key",
                str(Path(key).expanduser().absolute()),
            ],
            input=value.encode(),
            capture_output=True,
        )
        if result.returncode:
            raise RuntimeError(
                "SSH パスフレーズを保存できません。Secret Service を確認してください。"
            )

    @classmethod
    def remove(cls, key):
        result = subprocess.run(
            [
                cls.command(),
                "clear",
                "application",
                "dev.gitnebula.desktop",
                "key",
                str(Path(key).expanduser().absolute()),
            ],
            capture_output=True,
        )
        if result.returncode not in (0, 1):
            raise RuntimeError("保存した SSH パスフレーズを削除できません。")


def is_key_prompt(prompt, key):
    return prompt.strip() in (
        f"Enter passphrase for key '{key}':",
        f"Enter passphrase for '{key}':",
        f"Enter passphrase for {key}:",
    )


@contextlib.contextmanager
def git_environment(settings):
    environment = {
        **os.environ,
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_EDITOR": "true",
        "GIT_SEQUENCE_EDITOR": "true",
    }
    key = settings.values["ssh_key"]
    if not key:
        yield environment
        return
    with tempfile.TemporaryDirectory(prefix="gitnebula-ssh-") as temporary:
        wrapper = Path(temporary) / "ssh"
        helper = Path(temporary) / "askpass"
        wrapper.write_text(
            '#!/bin/sh\nexec /usr/bin/ssh -i "$GITNEBULA_SSH_KEY" -o IdentitiesOnly=yes -o PreferredAuthentications=publickey "$@"\n'
        )
        helper.write_text(
            "#!/bin/sh\nexec "
            + shlex.quote(sys.executable)
            + " "
            + shlex.quote(str(Path(__file__).with_name("main.py")))
            + ' "$@"\n'
        )
        wrapper.chmod(0o700)
        helper.chmod(0o700)
        environment.pop("GIT_SSH_COMMAND", None)
        environment.update(
            GIT_SSH=str(wrapper),
            GIT_SSH_VARIANT="ssh",
            GITNEBULA_SSH_KEY=str(Path(key).expanduser().absolute()),
            SSH_ASKPASS=str(helper),
            SSH_ASKPASS_REQUIRE="force",
            LC_ALL="C",
        )
        environment["GIT_SSH_COMMAND"] = shlex.quote(str(wrapper))
        yield environment


def clone_destination(parent, source):
    from urllib.parse import urlparse, unquote

    source = source.strip().rstrip("/\\")
    if "://" in source:
        name = unquote(urlparse(source).path).rstrip("/").split("/")[-1]
    else:
        name = source.replace("\\", "/").split("/")[-1].split(":")[-1]
    if name.endswith(".git"):
        name = name[:-4]
    if name in ("", ".", "..") or any(c in name for c in "\0/\\"):
        raise ValueError("取得元からリポジトリ名を判断できません。")
    return str(Path(parent).expanduser().absolute() / name)

import re
from dataclasses import dataclass


@dataclass(frozen=True)
class TransferProgress:
    stage: str
    percent: int | None = None
    completed: bool = False


class ProgressParser:
    def __init__(self, notify):
        self.notify, self.pending = notify, ""

    def feed(self, text):
        for character in text:
            if character in "\r\n":
                self.finish()
            else:
                self.pending = (self.pending + character)[-16384:]

    def finish(self):
        line = self.pending.strip().removeprefix("remote: ")
        self.pending = ""
        match = re.match(r"^(.*?):\s*(\d{1,3})%", line)
        if match and int(match[2]) <= 100:
            self.notify(TransferProgress(match[1], int(match[2])))
        elif line.startswith("Enumerating objects:"):
            self.notify(TransferProgress("オブジェクトを確認中…"))


@dataclass(frozen=True)
class TransferReport:
    action: str
    remote: str
    branch: str
    before: str | None
    after: str | None
    commits: int
    files: tuple[str, ...]
    output: str

    @property
    def summary(self):
        if self.action == "pull":
            return (
                "Pull 完了。最新のため変更はありません。"
                if self.before == self.after
                else f"Pull 完了。{self.commits} コミット、{len(self.files)} ファイルを更新しました。"
            )
        if self.action == "push":
            return f"Push 完了。{self.branch} を {self.remote} に送信しました。"
        return "Fetch 完了。リモートの追跡情報を更新しました。"

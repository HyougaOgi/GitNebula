"""Additional repository operations, using validated revisions and literal paths."""

import os
from pathlib import Path


class AdvancedTools:
    def selected_changes(self, files):
        changes = {c.path: c for c in self.changes()}
        if not files or any(f not in changes for f in files):
            raise ValueError("変更ファイルを選択してください。")
        return [changes[f] for f in files]

    def discard(self, files):
        self.require_idle()
        changes = self.selected_changes(files)
        if any(c.code == "??" or c.original or "A" in c.code for c in changes):
            raise ValueError(
                "新規・追加・名前変更ファイルは除外してください。既存ファイルの変更のみを元に戻せます。"
            )
        self.run(
            "--literal-pathspecs",
            "restore",
            "--source=HEAD",
            "--staged",
            "--worktree",
            "--",
            *files
        )

    def ignore(self, files):
        changes = self.selected_changes(files)
        if any(
            c.code != "??" or c.path == ".gitignore" or "\n" in c.path or "\r" in c.path
            for c in changes
        ):
            raise ValueError("無視対象にする未追跡ファイルのみを選択してください。")
        target = self.file_path(".gitignore")
        if target.is_symlink() or target.exists() and not target.is_file():
            raise ValueError(".gitignore が通常のファイルではありません。")
        content = target.read_text() if target.exists() else ""
        if content and not content.endswith("\n"):
            content += "\n"
        for file in files:
            content += (
                "/" + "".join("\\" + c if c in "\\!#*?[] " else c for c in file) + "\n"
            )
        target.write_text(content)

    def compare(self, first, second):
        return self.run(
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            self.revision(first),
            self.revision(second),
            "--",
            for_display=True,
        )

    def blame(self, file, reference="HEAD"):
        self.file_path(file)
        return self.run(
            "--literal-pathspecs",
            "blame",
            "--date=iso",
            self.revision(reference),
            "--",
            file,
            for_display=True,
        )

    def file_history(self, file):
        self.file_path(file)
        return self.run(
            "--literal-pathspecs",
            "log",
            "--follow",
            "--stat",
            "--format=%H%n%B",
            "-100",
            "--",
            file,
            for_display=True,
        )

    def reflog(self):
        return self.run(
            "reflog", "--date=iso", "--format=%H %gd %gs", "-100", for_display=True
        )

    def reset(self, reference, mode):
        self.require_clean()
        if mode not in ("soft", "mixed", "hard"):
            raise ValueError("Reset の方法が不正です。")
        self.run("reset", "--" + mode, self.revision(reference), "--")

    @staticmethod
    def absolute_path(value):
        target = Path(value).expanduser()
        if not target.is_absolute() or "\0" in value:
            raise ValueError("フォルダの絶対パスを入力してください。")
        return target

    def export_patch(self, path):
        target = self.absolute_path(path)
        self.revision("HEAD")
        # Reserve the target before asking Git to write it; existing files are preserved.
        descriptor = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(descriptor)
        try:
            self.run(
                "diff",
                "--no-ext-diff",
                "--no-textconv",
                "--binary",
                "--output=" + str(target),
                "HEAD",
                "--",
            )
        except Exception:
            target.unlink(missing_ok=True)
            raise

    def apply_patch(self, path, check_only=False):
        self.require_idle()
        target = str(self.absolute_path(path))
        self.run("apply", "--check", "--", target)
        if not check_only:
            self.run("apply", "--", target)

    def worktrees(self):
        return self.run("worktree", "list", "--porcelain", for_display=True)

    def add_worktree(self, path, branch):
        self.require_idle()
        target = self.absolute_path(path)
        if os.path.lexists(target):
            raise ValueError("作成先には、存在しないフォルダを指定してください。")
        self.run(
            "worktree",
            "add",
            "-b",
            self.validate_branch(branch),
            "--",
            str(target),
            "HEAD",
        )

    def submodules(self):
        return self.run("submodule", "status", "--recursive", for_display=True)

    def add_submodule(self, source, destination):
        self.require_clean()
        if not source or source.startswith("-") or not destination:
            raise ValueError("取得元とリポジトリ内の作成先を指定してください。")
        self.file_path(destination)
        self.run("submodule", "add", "--", source, destination)

    def update_submodules(self):
        self.require_clean()
        self.run("submodule", "update", "--init", "--recursive")

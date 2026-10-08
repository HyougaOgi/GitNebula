"""Full-file comparisons; Git supplies hunk positions for aligned rows."""

import re
import tempfile
from pathlib import Path
from dataclasses import dataclass


@dataclass(frozen=True)
class DiffRow:
    old_number: int | None
    new_number: int | None
    old: str
    new: str
    kind: str


@dataclass(frozen=True)
class DiffDocument:
    path: str
    old_title: str
    new_title: str
    rows: tuple
    hunks: tuple
    notice: str = ""

    @staticmethod
    def align(old, new, patch):
        rows, hunks, left, right = [], [], 0, 0

        def unchanged(end):
            nonlocal left, right
            if end < left or end > len(old):
                raise ValueError(
                    "差分の行情報を読み取れませんでした。更新して再度お試しください。"
                )
            while left < end:
                rows.append(
                    DiffRow(left + 1, right + 1, old[left], new[right], "unchanged")
                )
                left += 1
                right += 1

        for match in re.finditer(
            r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", patch, re.M
        ):
            start, count, after, added = (
                int(match[1]),
                int(match[2] or 1),
                int(match[3]),
                int(match[4] or 1),
            )
            start -= int(count > 0)
            after -= int(added > 0)
            unchanged(start)
            if right != after or start + count > len(old) or after + added > len(new):
                raise ValueError(
                    "差分の行情報を読み取れませんでした。更新して再度お試しください。"
                )
            hunks.append(len(rows))
            for offset in range(max(count, added)):
                a, b = start + offset if offset < count else None, (
                    after + offset if offset < added else None
                )
                rows.append(
                    DiffRow(
                        a + 1 if a is not None else None,
                        b + 1 if b is not None else None,
                        old[a] if a is not None else "",
                        new[b] if b is not None else "",
                        (
                            "added"
                            if a is None
                            else "removed" if b is None else "modified"
                        ),
                    )
                )
            left += count
            right += added
        unchanged(len(old))
        if right != len(new):
            raise ValueError(
                "差分の行情報を読み取れませんでした。更新して再度お試しください。"
            )
        return tuple(rows), tuple(hunks)


class FileDiffTools:
    def blob_text(self, revision, path):
        self.file_path(path)
        if revision is None:
            return ""
        object = revision + ":" + path
        try:
            size = int(self.run("cat-file", "-s", object))
        except RuntimeError:
            return ""
        if size > 1024 * 1024:
            raise ValueError("1 MiB を超えるファイルは表示できません。")
        return self.run("cat-file", "-p", object, for_display=True)

    def file_comparison(self, path, revision=None, parent=None, original=None):
        self.file_path(path)
        if revision:
            revision = self.revision(revision)
            if parent is None:
                parents = self.run("rev-list", "--parents", "-1", revision).split()[1:]
                parent = parents[0] if parents else None
            elif parent:
                parent = self.revision(parent)
            old = self.blob_text(parent or None, original or path)
            new = self.blob_text(revision, path)
            old_title, new_title = parent or "空のツリー", revision
        else:
            change = next((c for c in self.changes() if c.path == path), None)
            if change is None:
                raise ValueError("変更ファイルを選択してください。")
            old = self.blob_text(self.head(), change.original or path)
            target = self.file_path(path)
            if (
                target.exists()
                and target.is_file()
                and target.stat().st_size > 1024 * 1024
            ):
                return DiffDocument(
                    path,
                    "HEAD",
                    "作業ファイル",
                    (),
                    (),
                    "1 MiB を超えるファイルは表示できません。",
                )
            new = (
                self.run("submodule", "status", "--", path)
                if target.is_dir()
                else self.read_file(path)
            )
            old_title, new_title = "HEAD", "作業ファイル"
        if "\0" in old or "\0" in new or new.startswith("バイナリ"):
            return DiffDocument(
                path,
                old_title,
                new_title,
                (),
                (),
                "バイナリファイルは外部で確認してください。",
            )
        notices = []
        if old and not old.endswith("\n") or new and not new.endswith("\n"):
            notices.append("末尾に改行がないファイルがあります。")
        with tempfile.TemporaryDirectory(prefix="nebula-diff-") as directory:
            a, b = Path(directory) / "before", Path(directory) / "after"
            a.write_text(old)
            b.write_text(new)
            patch = self.run(
                "diff",
                "--no-index",
                "--no-ext-diff",
                "--no-textconv",
                "--text",
                "--unified=0",
                "--",
                str(a),
                str(b),
                accepting=(0, 1),
                for_display=True,
            )

        def lines(text):
            parts = text.split("\n") if text else []
            return parts[:-1] if parts and parts[-1] == "" else parts

        rows, hunks = DiffDocument.align(lines(old), lines(new), patch)
        return DiffDocument(path, old_title, new_title, rows, hunks, "\n".join(notices))

    def revision_files(self, revision, parent=None):
        revision = self.revision(revision)
        if parent is None:
            parents = self.run("rev-list", "--parents", "-1", revision).split()[1:]
            parent = parents[0] if parents else None
        if parent:
            output = self.run(
                "diff",
                "--name-status",
                "-z",
                "-M",
                self.revision(parent),
                revision,
                "--",
            )
        else:
            output = self.run(
                "diff-tree",
                "--root",
                "--no-commit-id",
                "--name-status",
                "-r",
                "-z",
                "-M",
                revision,
                "--",
            )
        fields, result = iter(output.split("\0")), []
        for code in fields:
            if not code:
                continue
            first = next(fields)
            original, path = (first, next(fields)) if code[0] in "RC" else (None, first)
            result.append((code, path, original))
        return result

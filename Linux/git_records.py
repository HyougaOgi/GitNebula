"""Repository records and work operations, shared by the GTK screens and tests."""

from dataclasses import dataclass
from pathlib import Path
from transfer import TransferReport


@dataclass(frozen=True)
class CommitField:
    id: str
    title: str
    value: str


@dataclass(frozen=True)
class CommitRecord:
    id: str
    author: str
    date: str
    subject: str
    message: str
    parents: tuple[str, ...]
    decorations: str = ""
    email: str = ""
    committer: str = ""
    committer_email: str = ""
    commit_date: str = ""
    tree: str = ""
    branch_names: tuple[str, ...] | None = None

    @property
    def detail_fields(self):
        rows = [
            ("id", "コミット ID", self.id),
            ("message", "メッセージ", self.message),
            ("author", "作成者", self.author),
            ("email", "作成者のメール", self.email),
            ("authorDate", "作成日時", self.date),
            ("committer", "コミットした人", self.committer),
            ("committerEmail", "コミットした人のメール", self.committer_email),
            ("commitDate", "コミット日時", self.commit_date),
            ("parents", "親コミット", "\n".join(self.parents)),
            ("references", "ブランチ・タグ", self.decorations),
            ("tree", "ツリー ID", self.tree),
        ]
        return tuple(CommitField(*r) for r in rows if r[2])

    @property
    def details_text(self):
        return "\n\n".join(f"{f.title}:\n{f.value}" for f in self.detail_fields)


@dataclass(frozen=True)
class BranchRecord:
    id: str
    name: str
    subject: str
    upstream: str
    remote: str = ""

    @property
    def local_name(self):
        return self.name[len(self.remote) + 1 :] if self.remote else self.name


@dataclass(frozen=True)
class StashRecord:
    reference: str
    id: str
    title: str


class RepositoryTools:
    def head(self):
        return (
            self.run(
                "rev-parse", "--verify", "--quiet", "HEAD", accepting=(0, 1)
            ).strip()
            or None
        )

    def configuration(self, key):
        return self.run("config", "--get", key, accepting=(0, 1)).removesuffix("\n")

    def sequence(self):
        for marker, operation in [
            ("rebase-merge", "rebase"),
            ("rebase-apply", "rebase"),
            ("CHERRY_PICK_HEAD", "cherry-pick"),
            ("REVERT_HEAD", "revert"),
            ("MERGE_HEAD", "merge"),
        ]:
            file = self.run(
                "rev-parse", "--path-format=absolute", "--git-path", marker
            ).removesuffix("\n")
            if Path(file).exists():
                return operation
        return None

    def require_idle(self):
        if self.sequence() or self.conflicts():
            raise ValueError("競合を解決し、進行中の操作を完了または中止してください。")

    def revision(self, reference):
        if not reference or "\0" in reference:
            raise ValueError("コミット・ブランチ・タグを指定してください。")
        return self.run(
            "rev-parse", "--verify", "--end-of-options", reference + "^{commit}"
        ).strip()

    def history(self, limit=200, topological=False, reference=None):
        if not self.run("rev-list", "--all", "--max-count=1").strip():
            return []
        raw = self.run(
            "log",
            self.revision(reference) if reference else "--all",
            "--topo-order" if topological else "--date-order",
            "--decorate=short",
            "-z",
            "-" + str(limit),
            "--format=%H%x00%an%x00%aI%x00%s%x00%B%x00%P%x00%D%x00%ae%x00%cn%x00%ce%x00%cI%x00%T",
            for_display=True,
        ).split("\0")
        branch_names = {}
        if topological:
            refs = self.run(
                "for-each-ref",
                "--format=%(objectname)%00%(refname)%00%(symref)",
                "refs/heads",
                "refs/remotes",
            )
            for line in refs.splitlines():
                parts = line.split("\0")
                if len(parts) != 3 or parts[2]:
                    continue
                prefix = (
                    "refs/heads/"
                    if parts[1].startswith("refs/heads/")
                    else "refs/remotes/"
                )
                name = parts[1][len(prefix) :]
                branch_names.setdefault(parts[0], []).append(name)
        return [
            CommitRecord(
                raw[i].lstrip("\n\r"),
                *raw[i + 1 : i + 5],
                tuple(raw[i + 5].split()),
                *raw[i + 6 : i + 12],
                branch_names=(
                    tuple(branch_names.get(raw[i].lstrip("\n\r"), ()))
                    if topological
                    else None
                ),
            )
            for i in range(0, len(raw) - 11, 12)
        ]

    def show_commit(self, reference):
        return self.run(
            "show",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--stat",
            "--patch",
            self.revision(reference),
            "--",
            for_display=True,
        )

    def branch_records(self, include_remote=False):
        args = [
            "for-each-ref",
            "--format=%(refname)%00%(subject)%00%(upstream:short)%00%(symref)",
            "refs/heads",
        ]
        if include_remote:
            args.append("refs/remotes")
        rows = [r.split("\0") for r in self.run(*args).splitlines()]
        rows = [r for r in rows if len(r) == 4 and not r[3]]
        tracked = {r[2] for r in rows if r[0].startswith("refs/heads/")}
        remotes = sorted(self.remotes(), key=len, reverse=True)
        records = []
        for reference, subject, upstream, _ in rows:
            local = reference.startswith("refs/heads/")
            name = reference[11 if local else 13 :]
            remote = (
                ""
                if local
                else next((r for r in remotes if name.startswith(r + "/")), "")
            )
            if remote and name in tracked:
                continue
            records.append(
                BranchRecord(
                    name if local else reference, name, subject, upstream, remote
                )
            )
        return records

    def transfer(self, action, remote, progress=None, all_branches=False):
        remote = self.remote(remote)
        before = self.head()
        branch = self.branch()
        if action == "pull":
            self.require_clean()
            args = [
                "pull",
                "--progress",
                "--ff-only",
                remote,
                self.remote_branch(remote),
            ]
        elif action == "push":
            if before is None:
                raise ValueError("Push する前に最初のコミットを作成してください。")
            args = [
                "push",
                "--progress",
                "--set-upstream",
                remote,
                "HEAD:" + self.remote_branch(remote),
            ]
        elif action == "fetch":
            args = ["fetch", "--progress", "--prune", remote]
            if all_branches:
                args.append("+refs/heads/*:refs/remotes/" + remote + "/*")
        else:
            raise ValueError("送受信の操作を選択してください。")
        output = self.run(*args, progress=progress) + self.last_diagnostics
        after = self.head()
        changed = action == "pull" and before and after and before != after
        count = (
            int(self.run("rev-list", "--count", before + ".." + after, "--"))
            if changed
            else 0
        )
        files = (
            tuple(
                p
                for p in self.run(
                    "diff", "--name-only", "-z", before, after, "--"
                ).split("\0")
                if p
            )
            if changed
            else ()
        )
        return TransferReport(
            action, remote, branch, before, after, count, files, output
        )

    def cherry_pick(self, reference):
        self.require_clean()
        return self.run("cherry-pick", self.revision(reference))

    def revert(self, reference):
        self.require_clean()
        return self.run("revert", "--no-edit", self.revision(reference))

    def rebase(self, reference):
        self.require_clean()
        return self.run("rebase", self.revision(reference))

    def continue_sequence(self):
        operation = self.sequence()
        if operation not in ("rebase", "cherry-pick", "revert") or self.conflicts():
            raise ValueError("競合を解決してから再開してください。")
        return self.run(operation, "--continue")

    def abort_sequence(self):
        operation = self.sequence()
        if operation is None:
            raise ValueError("進行中の操作はありません。")
        return self.run(operation, "--abort")

    def stage(self, files):
        self.require_idle()
        changes = self.changes()
        chosen = [c for c in changes if c.path in files]
        if not files or len(chosen) != len(set(files)):
            raise ValueError("変更ファイルを選択してください。")
        originals = [c.original for c in chosen if c.original]
        if any(o not in files and (Path(self.path) / o).exists() for o in originals):
            raise ValueError(
                "名前変更元に未選択のファイルがあります。そのファイルも選択してください。"
            )
        return self.run(
            "--literal-pathspecs",
            "add",
            "-A",
            "--",
            *dict.fromkeys([*files, *originals]),
        )

    def unstage(self, files):
        self.require_idle()
        changes = self.changes()
        if not files or not set(files).issubset({c.path for c in changes}):
            raise ValueError("変更ファイルを選択してください。")
        staged = [c for c in changes if c.path in files and c.code[0] not in (" ", "?")]
        if not staged:
            raise ValueError("選択したファイルにステージ済みの変更はありません。")
        paths = list(
            dict.fromkeys(
                [c.path for c in staged] + [c.original for c in staged if c.original]
            )
        )
        return self.run(
            "--literal-pathspecs",
            *(["restore", "--staged"] if self.head() else ["rm", "--cached", "-f"]),
            "--",
            *paths,
        )

    def stashes(self):
        rows = [
            r.split("\0", 2)
            for r in self.run("stash", "list", "--format=%gd%x00%H%x00%gs").splitlines()
        ]
        return [StashRecord(*r) for r in rows if len(r) == 3]

    def save_stash(self, message, include_untracked=True):
        self.require_idle()
        if not any(include_untracked or c.code != "??" for c in self.changes()):
            raise ValueError(
                "退避する変更がありません。未追跡ファイルを含める場合はチェックを入れてください。"
            )
        if self.head() is None:
            raise ValueError("Stash を使う前に最初のコミットを作成してください。")
        return self.run(
            "stash",
            "push",
            *(["--include-untracked"] if include_untracked else []),
            "-m",
            message or "GitNebula",
        )

    def stash_reference(self, id):
        record = next((s for s in self.stashes() if s.id == id), None)
        if record is None:
            raise ValueError("退避データが見つかりません。一覧を更新してください。")
        return record.reference

    def apply_stash(self, id, pop=False):
        self.require_clean()
        return self.run(
            "stash", "pop" if pop else "apply", "--index", self.stash_reference(id)
        )

    def drop_stash(self, id):
        self.require_idle()
        return self.run("stash", "drop", self.stash_reference(id))

    def show_stash(self, id):
        return self.run(
            "stash",
            "show",
            "--include-untracked",
            "--no-ext-diff",
            "--no-textconv",
            "--patch",
            self.stash_reference(id),
            for_display=True,
        )

    def tags(self):
        return self.run("tag", "--list", "--sort=-creatordate").splitlines()

    def validate_tag(self, name):
        if not name or name.startswith("-"):
            raise ValueError("タグ名を指定してください。")
        self.run("check-ref-format", "refs/tags/" + name)

    def create_tag(self, name, reference="HEAD", message=""):
        self.validate_tag(name)
        id = self.revision(reference)
        return self.run(
            "tag", *(["-a", "-m", message] if message else []), "--", name, id
        )

    def delete_tag(self, name):
        self.validate_tag(name)
        return self.run("tag", "-d", "--", name)

    def push_tag(self, name, remote):
        self.validate_tag(name)
        if name not in self.tags():
            raise ValueError("ローカルのタグを選択してください。")
        return self.run(
            "push", self.remote(remote), "refs/tags/" + name + ":refs/tags/" + name
        )

    def set_remote(self, name, url):
        if (
            not name
            or name.startswith("-")
            or not url
            or url.startswith("-")
            or "\0" in url
        ):
            raise ValueError("リモート名と URL を指定してください。")
        self.run("check-ref-format", "refs/remotes/" + name + "/probe")
        return self.run(
            "remote", "set-url" if name in self.remotes() else "add", name, url
        )

    def remove_remote(self, name):
        return self.run("remote", "remove", self.remote(name))

    def set_identity(self, name, email):
        if not name.strip() or not email.strip():
            raise ValueError("名前とメールアドレスを入力してください。")
        self.run("config", "--local", "user.name", name)
        self.run("config", "--local", "user.email", email)

    @classmethod
    def initialize(cls, directory):
        target = Path(directory).expanduser().absolute()
        if not target.is_dir():
            raise ValueError("作成済みのフォルダを選択してください。")
        try:
            cls(str(target))
        except RuntimeError:
            pass
        else:
            raise ValueError("既存リポジトリ内には作成しません。")
        runner = cls.__new__(cls)
        runner.path = str(target)
        runner.run("init", "--")
        return cls(str(target))

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Linux"))
from git_backend import Repository
from graph import (
    branch_names,
    branch_logs,
    branch_links,
    graph_rows,
    OrbitCamera,
    volume_pixels,
)
from git_records import CommitRecord
from transfer import ProgressParser
from settings import (
    Settings,
    SecretStore,
    clone_destination,
    git_environment,
    is_key_prompt,
)


class ParityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nebula-parity-")
        self.root = Path(self.temporary.name)
        self.environment = patch.dict(
            os.environ, {"GITNEBULA_SETTINGS_PATH": str(self.root / "settings.json")}
        )
        self.environment.start()
        self.source = self.root / "source"
        self.source.mkdir()
        subprocess.run(
            ["git", "init", "-q", "-b", "main", str(self.source)], check=True
        )
        self.repo = Repository(str(self.source))
        self.repo.set_identity("Committer", "committer@example.invalid")
        (self.source / "base.txt").write_text("base\n")
        self.repo.commit(
            ["base.txt"], "Subject\n\nBody first\nBody second\n\nReviewed-by: Test"
        )

    def tearDown(self):
        self.environment.stop()
        self.temporary.cleanup()

    def test_graph_names_come_from_real_refs_without_symbolic_aliases(self):
        id = self.repo.head()
        self.repo.run("branch", "release/HEAD")
        self.repo.run("tag", "v1")
        self.repo.run("update-ref", "refs/remotes/team/release/HEAD", id)
        self.repo.run(
            "symbolic-ref", "refs/remotes/team/HEAD", "refs/remotes/team/release/HEAD"
        )
        self.repo.run("update-ref", "refs/notes/review", id)
        commits = self.repo.history(topological=True)
        self.assertEqual(
            commits[0].branch_names, ("main", "release/HEAD", "team/release/HEAD")
        )
        self.assertEqual(
            branch_logs(commits)[0].title, "main, release/HEAD, team/release/HEAD"
        )

    def test_details_match_object_and_copy_values_preserve_body(self):
        record = self.repo.history()[0]
        raw = self.repo.run("cat-file", "commit", record.id)
        body = raw.split("\n\n", 1)[1]
        self.assertEqual(record.id, self.repo.revision("HEAD"))
        self.assertEqual(record.message, body)
        self.assertEqual(len(record.id), 40)
        self.assertEqual(record.email, "committer@example.invalid")
        self.assertEqual(record.committer, "Committer")
        self.assertEqual(record.committer_email, record.email)
        self.assertTrue(raw.startswith("tree " + record.tree + "\n"))
        for field in record.detail_fields:
            self.assertIn(field.value, record.details_text)
        self.repo.create_branch("feature")
        (self.source / "feature").write_text("feature")
        self.repo.commit(["feature"], "feature")
        self.repo.switch_branch("main")
        (self.source / "main").write_text("main")
        self.repo.commit(["main"], "main")
        self.repo.merge("feature")
        self.repo.create_tag("release", "HEAD", "release note")
        merged = self.repo.history()[0]
        self.assertEqual(len(merged.parents), 2)
        self.assertIn("\n".join(merged.parents), merged.details_text)
        self.assertIn("tag: release", merged.decorations)
        self.assertEqual(
            {c.id for c in self.repo.history(reference="feature")},
            {self.repo.revision("feature"), record.id},
        )

    def test_advanced_operations_and_existing_file_protection(self):
        first = self.repo.head()
        file = self.source / "base.txt"
        file.write_text("next\n")
        self.repo.commit(["base.txt"], "next")
        second = self.repo.head()
        self.assertIn("+next", self.repo.compare(first, second))
        self.assertIn("Committer", self.repo.blame("base.txt"))
        self.assertIn(first, self.repo.file_history("base.txt"))
        self.assertIn(second, self.repo.reflog())
        (self.source / "keep.tmp").write_text("preserved")
        with self.assertRaises((RuntimeError, ValueError)):
            self.repo.reset(first, "hard")
        self.assertEqual(self.repo.head(), second)
        self.assertEqual((self.source / "keep.tmp").read_text(), "preserved")
        self.repo.ignore(["keep.tmp"])
        self.assertFalse(any(c.path == "keep.tmp" for c in self.repo.changes()))
        self.repo.commit([".gitignore"], "ignore")
        file.write_text("patch value\n")
        output = self.root / "changes.patch"
        self.repo.export_patch(str(output))
        with self.assertRaises(FileExistsError):
            self.repo.export_patch(str(output))
        self.assertIn("+patch value", output.read_text())
        self.repo.discard(["base.txt"])
        self.assertEqual(file.read_text(), "next\n")
        self.repo.apply_patch(str(output), True)
        self.assertEqual(file.read_text(), "next\n")
        self.repo.apply_patch(str(output))
        self.assertEqual(file.read_text(), "patch value\n")
        self.repo.discard(["base.txt"])
        self.repo.reset(second, "soft")
        self.assertEqual(self.repo.head(), second)
        self.assertIn(".gitignore", [c.path for c in self.repo.changes()])
        self.repo.commit([".gitignore"], "ignore again")
        target = self.root / "worktree"
        self.repo.add_worktree(str(target), "worktree-branch")
        self.assertEqual(Repository(str(target)).branch(), "worktree-branch")
        self.assertIn(str(target), self.repo.worktrees())
        with self.assertRaises(ValueError):
            self.repo.add_worktree(str(target), "other")
        with self.assertRaises(ValueError):
            self.repo.blame("../outside")

    def test_submodule_add_and_recorded_revision_update(self):
        source = self.root / "module"
        source.mkdir()
        subprocess.run(["git", "init", "-q", str(source)], check=True)
        module = Repository(str(source))
        module.set_identity("Test", "test@example.invalid")
        (source / "module.txt").write_text("initial\n")
        module.commit(["module.txt"], "module")
        with patch.dict(
            os.environ,
            {
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "protocol.file.allow",
                "GIT_CONFIG_VALUE_0": "always",
            },
        ):
            self.repo.add_submodule(str(source), "dependencies/module")
            self.assertIn(module.head(), self.repo.submodules())
            self.repo.commit([".gitmodules", "dependencies/module"], "add module")
            self.repo.update_submodules()
            self.assertEqual(
                Repository(str(self.source / "dependencies/module")).head(),
                module.head(),
            )

    def test_full_file_alignment_renames_root_and_binary(self):
        file = self.source / "base.txt"
        file.write_text("base\ninserted\n")
        document = self.repo.file_comparison("base.txt")
        self.assertEqual(
            [(r.old_number, r.new_number, r.kind) for r in document.rows],
            [(1, 1, "unchanged"), (None, 2, "added")],
        )
        self.assertEqual(document.hunks, (1,))
        self.repo.commit(["base.txt"], "insert")
        self.repo.run("mv", "base.txt", "renamed.txt")
        self.repo.commit(["renamed.txt"], "rename")
        files = self.repo.revision_files("HEAD")
        self.assertEqual(files, [("R100", "renamed.txt", "base.txt")])
        renamed = self.repo.file_comparison("renamed.txt", "HEAD", original="base.txt")
        self.assertTrue(all(r.kind == "unchanged" for r in renamed.rows))
        initial = self.repo.history()[-1]
        first = self.repo.file_comparison("base.txt", initial.id)
        self.assertEqual(first.rows[0].kind, "added")
        (self.source / "binary").write_bytes(b"a\0b")
        binary = self.repo.file_comparison("binary")
        self.assertEqual(binary.rows, ())
        self.assertIn("バイナリ", binary.notice)

    def remote_fixture(self):
        self.repo.create_branch("feature/nested")
        (self.source / "feature").write_text("feature")
        self.repo.commit(["feature"], "feature")
        self.repo.switch_branch("main")
        bare = self.root / "remote.git"
        subprocess.run(
            ["git", "clone", "-q", "--bare", str(self.source), str(bare)], check=True
        )
        clone = self.root / "clone"
        subprocess.run(
            ["git", "clone", "-q", "--single-branch", str(bare), str(clone)], check=True
        )
        return bare, Repository(str(clone))

    def test_single_branch_clone_refresh_and_remote_tracking(self):
        bare, clone = self.remote_fixture()
        self.assertEqual(clone.branches(), ["main"])
        self.assertFalse(any(b.remote for b in clone.branch_records(True)))
        report = clone.transfer("fetch", "origin", all_branches=True)
        self.assertEqual(report.before, report.after)
        record = next(
            b for b in clone.branch_records(True) if b.name == "origin/feature/nested"
        )
        self.assertEqual(record.local_name, "feature/nested")
        self.assertFalse(
            any(b.name == "origin/HEAD" for b in clone.branch_records(True))
        )
        clone.switch_branch(record.id)
        self.assertEqual(clone.branch(), "feature/nested")
        self.assertEqual(clone.configuration("branch.feature/nested.remote"), "origin")
        self.assertEqual(
            clone.configuration("branch.feature/nested.merge"),
            "refs/heads/feature/nested",
        )
        self.assertEqual(clone.revision("HEAD"), self.repo.revision("feature/nested"))
        self.assertEqual((Path(clone.path) / "feature").read_text(), "feature")
        self.assertFalse(
            any(b.name == "origin/feature/nested" for b in clone.branch_records(True))
        )
        mappings = clone.run("config", "--get-all", "remote.origin.fetch")
        self.assertIn("+refs/heads/main:refs/remotes/origin/main", mappings)
        self.assertIn(
            "+refs/heads/feature/nested:refs/remotes/origin/feature/nested", mappings
        )

    def test_dirty_work_and_existing_local_name_are_preserved(self):
        bare, clone = self.remote_fixture()
        clone.transfer("fetch", "origin", all_branches=True)
        before = clone.head()
        root = Path(clone.path)
        (root / "dirty").write_text("keep")
        with self.assertRaises(ValueError):
            clone.switch_branch("refs/remotes/origin/feature/nested")
        self.assertEqual(clone.head(), before)
        self.assertEqual((root / "dirty").read_text(), "keep")
        (root / "dirty").unlink()
        clone.run("branch", "feature/nested", "main")
        with self.assertRaises(ValueError):
            clone.switch_branch("refs/remotes/origin/feature/nested")
        self.assertEqual(clone.head(), before)
        self.assertEqual(clone.revision("feature/nested"), before)

    def test_multiline_selected_commit_and_stage_unstage(self):
        (self.source / "base.txt").write_text("selected")
        (self.source / "keep").write_text("unselected")
        self.repo.stage(["keep"])
        self.repo.unstage(["base.txt", "keep"])
        self.repo.commit(["base.txt"], "Multiline\n\nFull body\n\nTrailer: value")
        self.assertEqual(
            self.repo.history()[0].message, "Multiline\n\nFull body\n\nTrailer: value\n"
        )
        self.assertEqual([c.path for c in self.repo.changes()], ["keep"])
        self.assertEqual((self.source / "keep").read_text(), "unselected")

    def test_stash_stable_ids_and_untracked_guard(self):
        (self.source / "new").write_text("new")
        with self.assertRaises(ValueError):
            self.repo.save_stash("no op", False)
        self.repo.save_stash("first", True)
        first = self.repo.stashes()[0]
        (self.source / "base.txt").write_text("second")
        self.repo.save_stash("second", False)
        self.assertEqual(self.repo.stash_reference(first.id), "stash@{1}")
        self.repo.apply_stash(first.id)
        self.assertEqual((self.source / "new").read_text(), "new")
        self.assertEqual(len(self.repo.stashes()), 2)
        self.repo.commit(["new"], "restore")
        self.repo.drop_stash(first.id)
        second = self.repo.stashes()[0]
        self.repo.apply_stash(second.id, True)
        self.assertEqual((self.source / "base.txt").read_text(), "second")
        self.assertEqual(self.repo.stashes(), [])

    def test_history_operations_and_conflict_recovery(self):
        self.repo.create_branch("incoming")
        (self.source / "picked").write_text("picked")
        self.repo.commit(["picked"], "pick")
        pick = self.repo.head()
        self.repo.switch_branch("main")
        self.repo.cherry_pick(pick)
        self.repo.revert(self.repo.head())
        self.assertFalse((self.source / "picked").exists())
        self.repo.switch_branch("incoming")
        (self.source / "base.txt").write_text("incoming")
        self.repo.commit(["base.txt"], "incoming conflict")
        conflict = self.repo.head()
        self.repo.switch_branch("main")
        (self.source / "base.txt").write_text("current")
        self.repo.commit(["base.txt"], "current")
        with self.assertRaises(RuntimeError):
            self.repo.cherry_pick(conflict)
        self.assertEqual(self.repo.sequence(), "cherry-pick")
        with self.assertRaises(ValueError):
            self.repo.rename_branch("main", "unexpected")
        self.repo.save_resolution("base.txt", "resolved\n")
        self.repo.continue_sequence()
        self.assertIsNone(self.repo.sequence())
        self.repo.switch_branch("incoming")
        before = self.repo.head()
        with self.assertRaises(RuntimeError):
            self.repo.rebase("main")
        self.assertEqual(self.repo.sequence(), "rebase")
        self.repo.abort_sequence()
        self.assertEqual(self.repo.head(), before)

    def test_clone_automatic_name_nonempty_parent_and_init_guard(self):
        destination = clone_destination(str(self.root), str(self.source))
        self.assertEqual(destination, str(self.root / "source"))
        destination = clone_destination(
            str(self.root / "parent"), "git@example.invalid:team/repo.git"
        )
        self.assertEqual(destination, str(self.root / "parent/repo"))
        parent = self.root / "parent"
        parent.mkdir()
        (parent / "keep").write_text("keep")
        target = clone_destination(str(parent), str(self.source))
        clone = Repository.clone(str(self.source), target)
        self.assertEqual(clone.head(), self.repo.head())
        self.assertEqual((parent / "keep").read_text(), "keep")
        with self.assertRaises(ValueError):
            Repository.clone(str(self.source), target)
        empty = self.root / "init"
        empty.mkdir()
        (empty / "keep").write_text("keep")
        initialized = Repository.initialize(str(empty))
        self.assertIsNone(initialized.head())
        self.assertEqual((empty / "keep").read_text(), "keep")
        with self.assertRaises(ValueError):
            Repository.initialize(str(empty))

    def test_live_transfer_progress_reports_real_stage_percentages(self):
        bare = self.root / "progress.git"
        subprocess.run(
            ["git", "clone", "-q", "--bare", str(self.source), str(bare)], check=True
        )
        progress = []
        target = self.root / "stream-clone"
        clone = Repository.clone(bare.as_uri(), str(target), progress.append)
        self.assertTrue(any(p.percent is not None for p in progress))
        self.assertTrue(
            all(p.percent is None or 0 <= p.percent <= 100 for p in progress)
        )
        clone.set_identity("Test", "test@example.invalid")
        (target / "base.txt").write_text("reply")
        clone.commit(["base.txt"], "reply")
        clone.transfer("push", "origin", progress.append)
        self.repo.set_remote("origin", str(bare))
        self.repo.transfer("fetch", "origin", progress.append)
        report = self.repo.transfer("pull", "origin", progress.append)
        self.assertEqual(clone.head(), self.repo.head())
        self.assertEqual(report.commits, 1)
        self.assertEqual(report.files, ("base.txt",))
        self.assertNotEqual(report.before, report.after)

    def test_progress_chunking_and_diagnostics_before_exit(self):
        events = []
        parser = ProgressParser(events.append)
        for chunk in [
            "remote: Counting obj",
            "ects: 5",
            "0% (1/2)\r",
            "Counting objects: 100% (2/2)\n",
            "fatal: detail\n",
        ]:
            parser.feed(chunk)
        self.assertEqual([p.percent for p in events], [50, 100])
        wrapper = self.root / "fake-git"
        wrapper.write_text(
            '#!/bin/sh\nprintf "Counting objects: 25%% (1/4)\\r" >&2\nIFS= read -r value < "$GITNEBULA_GATE"\nprintf "done\\000data"\nprintf "diagnostic\\n" >&2\n'
        )
        wrapper.chmod(0o700)
        gate = self.root / "gate"
        os.mkfifo(gate)
        settings = Settings()
        settings.values["git_executable"] = str(wrapper)
        settings.save()
        from concurrent.futures import ThreadPoolExecutor
        from threading import Event

        event = Event()
        with patch.dict(
            os.environ, {"GITNEBULA_GATE": str(gate)}
        ), ThreadPoolExecutor() as executor:
            pending = executor.submit(
                self.repo.run, "fetch", progress=lambda p: event.set()
            )
            arrived = event.wait(5)
            with gate.open("w") as stream:
                stream.write("continue\n")
            output = pending.result(5)
        self.assertTrue(arrived)
        self.assertEqual(output, "done\0data")
        self.assertEqual(
            self.repo.last_diagnostics, "Counting objects: 25% (1/4)\rdiagnostic\n"
        )

    def test_secret_service_stdin_and_selected_key_only(self):
        key = str(self.root / "key ' 日本語")
        settings = Settings()
        settings.values["ssh_key"] = key
        settings.save()
        self.assertTrue(is_key_prompt(f"Enter passphrase for key '{key}': ", key))
        for prompt in ["other's password: ", "Enter passphrase for key '/other': "]:
            self.assertFalse(is_key_prompt(prompt, key))
        with git_environment(settings) as environment:
            self.assertEqual(environment["GITNEBULA_SSH_KEY"], key)
            self.assertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
            self.assertNotIn("passphrase", Path(environment["GIT_SSH"]).read_text())
            self.assertTrue(Path(environment["SSH_ASKPASS"]).is_file())
        self.assertNotIn("passphrase", settings.path.read_text().lower())
        with patch("settings.shutil.which", return_value="/usr/bin/secret-tool"), patch(
            "settings.subprocess.run",
            return_value=subprocess.CompletedProcess([], 0, b"", b""),
        ) as run:
            SecretStore.save(key, "secret value")
            args, kwargs = run.call_args
            self.assertNotIn("secret value", args[0])
            self.assertEqual(kwargs["input"], b"secret value")


class GraphParityTests(unittest.TestCase):
    def test_branch_names_ignore_tags_and_resolve_merged_logs(self):
        def record(id, parents=(), refs=""):
            return CommitRecord(id, "Tester", "2026-10-09", id, id, parents, refs)

        commits = [
            record(
                "tip", ("merge",), "tag: v2, origin/main, HEAD -> main, origin/HEAD"
            ),
            record("merge", ("old", "merged")),
            record("old", ("base",)),
            record("base"),
            record(
                "feature", ("base",), "tag: v1, feature/topic, origin/feature/topic"
            ),
            record("merged", ("base",), "tag: deleted"),
            record("orphan", (), "tag: orphan"),
        ]
        branches = branch_logs(commits)
        labels = {c.id: b.title for b in branches for c in b.commits}
        self.assertEqual(labels["tip"], "main, origin/main")
        self.assertEqual(labels["feature"], "feature/topic, origin/feature/topic")
        self.assertEqual(labels["merged"], "main, origin/main")
        self.assertEqual(labels["orphan"], "orphan")
        self.assertEqual(sum(len(b.commits) for b in branches), len(commits))
        self.assertEqual(
            branch_names("HEAD, tag: v1, refs/stash, refs/notes/review"), ()
        )
        self.assertEqual(
            branch_names(
                "tag: v1, refs/heads/release/HEAD, refs/remotes/origin/release/HEAD, refs/remotes/origin/HEAD"
            ),
            ("release/HEAD", "origin/release/HEAD"),
        )

    def fixture(self):
        return [
            CommitRecord(
                f"{i:040x}",
                "Author",
                "2020-01-01T00:00:00Z",
                f"Commit {i}",
                "message\n",
                tuple(f"{p:040x}" for p in parents),
                decoration,
            )
            for i, parents, decoration in [
                (9, (8,), "HEAD -> main"),
                (8, (7, 4), ""),
                (7, (6,), ""),
                (6, (), ""),
                (5, (4,), "feature"),
                (4, (6,), ""),
                (3, (6,), "other"),
                (2, (6,), "fourth"),
            ]
        ]

    def test_topology_branch_logs_and_size(self):
        commits = self.fixture()
        rows = graph_rows(commits)
        branches = branch_logs(commits)
        links = branch_links(branches)
        self.assertEqual(len(rows), len(commits))
        self.assertEqual(
            {c.id for b in branches for c in b.commits}, {c.id for c in commits}
        )
        self.assertEqual(sum(len(b.commits) for b in branches), len(commits))
        membership = {c.id: b.id for b in branches for c in b.commits}
        expected = {
            (c.id, p)
            for c in commits
            for p in c.parents
            if p in membership and membership[c.id] != membership[p]
        }
        self.assertEqual(
            {relation for pairs in links.values() for relation in pairs}, expected
        )
        self.assertGreater(
            max(branches, key=lambda b: len(b.commits)).radius,
            min(branches, key=lambda b: len(b.commits)).radius,
        )
        import math

        a, b, c, d = [branch.position for branch in branches[:4]]
        v = [[p[i] - a[i] for i in range(3)] for p in [b, c, d]]
        determinant = (
            v[0][0] * (v[1][1] * v[2][2] - v[1][2] * v[2][1])
            - v[0][1] * (v[1][0] * v[2][2] - v[1][2] * v[2][0])
            + v[0][2] * (v[1][0] * v[2][1] - v[1][1] * v[2][0])
        )
        self.assertGreater(abs(determinant), 0.1)

    def test_camera_roundtrip_and_volume_is_spatial(self):
        camera = OrbitCamera()
        before = camera.project((2.0, 3.0, 4.0), 800, 500)
        image = volume_pixels(camera, 48, 30)
        camera.zoom(-1000)
        camera.zoom(1000)
        self.assertEqual(camera.project((2.0, 3.0, 4.0), 800, 500), before)
        self.assertEqual(volume_pixels(camera, 48, 30), image)
        camera.rotate(150, 70)
        self.assertNotEqual(camera.project((2.0, 3.0, 4.0), 800, 500), before)
        self.assertNotEqual(volume_pixels(camera, 48, 30), image)
        point = (1.0, 2.0, 3.0)
        restored = camera.inverse(camera.transform(point))
        for actual, expected in zip(restored, point):
            self.assertAlmostEqual(actual, expected)
        self.assertNotEqual(volume_pixels(OrbitCamera(), 48, 30, time=10), image)
        camera = OrbitCamera()
        camera.zoom(1000)
        self.assertGreater(max(volume_pixels(camera, 48, 30)[0::4]), 30)


if __name__ == "__main__":
    unittest.main()

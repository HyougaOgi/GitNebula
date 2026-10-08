from gi.repository import Gtk


class AdvancedViews:
    def build_advanced(self):
        self.advanced_outputs = {}
        for name in (
            "compare",
            "file-history",
            "blame",
            "reflog",
            "reset",
            "patch",
            "worktrees",
            "submodules",
        ):
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            output = Gtk.TextView(editable=False, monospace=True, vexpand=True)
            self.advanced_outputs[name] = output
            if name == "compare":
                first = self.entry(box, "比較元のコミット", "HEAD~1")
                second = self.entry(box, "比較先のコミット", "HEAD")

                def compare(a=first, b=second, v=output):
                    first, second = a.get_text(), b.get_text()
                    self.task(
                        lambda: self.repo.compare(first, second),
                        lambda text: v.get_buffer().set_text(text),
                    )

                box.append(self.button("比較", compare))
            elif name in ("file-history", "blame"):
                file = self.entry(box, "リポジトリ内のファイル")
                reference = (
                    self.entry(box, "対象コミット / ブランチ（例: HEAD）", "HEAD")
                    if name == "blame"
                    else None
                )

                def show(a=file, b=reference, v=output):
                    file, ref = a.get_text(), b.get_text() if b else None
                    self.task(
                        lambda: (
                            self.repo.blame(file, ref)
                            if ref is not None
                            else self.repo.file_history(file)
                        ),
                        lambda text: v.get_buffer().set_text(text),
                    )

                box.append(self.button("表示", show))
            elif name == "reset":
                reference = self.entry(
                    box, "対象コミット / ブランチ（例: HEAD）", "HEAD"
                )
                mode = Gtk.ComboBoxText()
                for value in ("soft", "mixed", "hard"):
                    mode.append(value, value)
                mode.set_active_id("soft")
                box.append(mode)

                def reset(a=reference, b=mode):
                    ref, mode = a.get_text(), b.get_active_id()
                    self.confirm(
                        self.L("現在のブランチを指定したコミットへ移動します。")
                        + "\n"
                        + ref
                        + " · "
                        + mode,
                        lambda: self.operate(lambda: self.repo.reset(ref, mode)),
                    )

                box.append(self.button("Reset", reset))
            elif name == "patch":
                file = self.entry(box, "パッチファイルの絶対パス")
                box.append(
                    self.button(
                        "ファイルを選択", lambda entry=file: self.choose_patch(entry)
                    )
                )

                def save(a=file):
                    path = a.get_text()
                    self.task(
                        lambda: self.repo.export_patch(path), lambda _: None, "完了"
                    )

                def apply(check, a=file):
                    path = a.get_text()
                    if check:
                        self.task(
                            lambda: self.repo.apply_patch(path, True),
                            lambda _: None,
                            "完了",
                        )
                    else:
                        self.confirm(
                            self.L("作業ファイルへパッチを適用します。") + "\n" + path,
                            lambda: self.operate(lambda: self.repo.apply_patch(path)),
                        )

                box.append(self.button("パッチを保存", save))
                box.append(
                    self.button(
                        "適用できるか確認", lambda callback=apply: callback(True)
                    )
                )
                box.append(
                    self.button("パッチを適用", lambda callback=apply: callback(False))
                )
            elif name == "worktrees":
                path = self.entry(box, "作成先の絶対パス")
                branch = self.entry(box, "新しいブランチ名")

                def worktree(a=path, b=branch):
                    path, branch = a.get_text(), b.get_text()
                    self.operate(lambda: self.repo.add_worktree(path, branch))

                box.append(self.button("Worktree を作成", worktree))
            elif name == "submodules":
                source = self.entry(box, "取得元 URL / パス")
                path = self.entry(box, "リポジトリ内の作成先")

                def submodule(a=source, b=path):
                    source, path = a.get_text(), b.get_text()
                    self.operate(lambda: self.repo.add_submodule(source, path))

                box.append(self.button("Submodule を追加", submodule))
                box.append(
                    self.button(
                        "Submodule を更新",
                        lambda: self.operate(self.repo.update_submodules),
                    )
                )
            scroll = Gtk.ScrolledWindow(vexpand=True)
            scroll.set_child(output)
            box.append(scroll)
            self.add_page(name, box)

    def choose_patch(self, entry):
        chooser = Gtk.FileChooserNative(
            title=self.L("ファイルを選択"),
            transient_for=self,
            action=Gtk.FileChooserAction.OPEN,
        )

        def response(dialog, answer):
            if answer == Gtk.ResponseType.ACCEPT:
                entry.set_text(dialog.get_file().get_path())
            dialog.destroy()

        chooser.connect("response", response)
        chooser.show()

    def ignore_selected(self):
        files = list(self.selected)
        self.operate(lambda: self.repo.ignore(files))

    def discard_selected(self):
        files = list(self.selected)
        self.confirm(
            self.L("選択したファイルの変更を破棄します。") + "\n" + "\n".join(files),
            lambda: self.operate(lambda: self.repo.discard(files)),
        )

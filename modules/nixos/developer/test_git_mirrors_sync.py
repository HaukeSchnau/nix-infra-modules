import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import git_mirrors_sync as mirrors

os.environ.update(
    GIT_AUTHOR_NAME="test",
    GIT_AUTHOR_EMAIL="test@example.test",
    GIT_COMMITTER_NAME="test",
    GIT_COMMITTER_EMAIL="test@example.test",
    GIT_CONFIG_GLOBAL=os.devnull,
    GIT_CONFIG_NOSYSTEM="1",
)

PR = "refs/heads/pr"
MAIN = "refs/heads/main"


def git(cwd, *args, stdin=None):
    return subprocess.run(["git", *args], cwd=cwd, input=stdin, check=True, capture_output=True, text=True).stdout.strip()


class Forge:
    """A bare repository standing in for Gitea or GitHub; writes to it are someone pushing there."""

    def __init__(self, path):
        self.path = path
        git(None, "init", "-q", "--bare", str(path))

    def commit(self, message, parent=None):
        tree = git(self.path, "mktree", stdin="")
        return git(self.path, "commit-tree", tree, "-m", message, *(["-p", parent] if parent else []))

    def push(self, ref, sha):
        git(self.path, "update-ref", ref, sha)

    def delete(self, ref):
        git(self.path, "update-ref", "-d", ref)

    def fetch(self, other, ref):
        git(self.path, "fetch", "-q", str(other.path), f"{ref}:{ref}")

    def get(self, ref):
        result = subprocess.run(["git", "rev-parse", "-q", "--verify", ref], cwd=self.path, capture_output=True, text=True)
        return result.stdout.strip() or None


class SyncTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.gitea = Forge(self.root / "gitea/me/demo.git")
        self.github = Forge(self.root / "github/me/demo.git")
        self.cfg = {
            "gitea": {"baseUrl": (self.root / "gitea").as_uri()},
            "github": {"baseUrl": (self.root / "github").as_uri()},
        }
        self.repo = {"name": "me__demo", "giteaPath": "me/demo", "githubPath": "me/demo", "empty": False}
        self.mirror_dir = self.root / "state/repositories/me__demo.git"
        self.main = self.gitea.commit("main")
        self.gitea.push(MAIN, self.main)

    def sync(self):
        mirrors.sync_repository(self.repo, self.cfg, str(self.root / "state"), str(self.root / "credentials"))

    def legacy_sync(self):
        """What the mirror did before it kept a record: force-push and prune everything."""
        refspecs = ["+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"]
        if not self.mirror_dir.exists():
            git(None, "init", "-q", "--bare", str(self.mirror_dir))
            git(self.mirror_dir, "remote", "add", "origin", str(self.gitea.path))
        git(self.mirror_dir, "fetch", "-q", "--prune", "--prune-tags", "origin", *refspecs)
        git(self.mirror_dir, "push", "-q", "--prune", str(self.github.path), *refspecs)

    def test_a_maintainer_push_survives_while_other_refs_keep_mirroring(self):
        mine = self.gitea.commit("pr")
        self.gitea.push(PR, mine)
        self.sync()
        theirs = self.github.commit("maintainer", parent=mine)
        self.github.push(PR, theirs)

        self.sync()
        self.sync()
        newer_main = self.gitea.commit("main 2", parent=self.main)
        self.gitea.push(MAIN, newer_main)
        self.sync()

        self.assertEqual(self.github.get(PR), theirs)
        self.assertEqual(self.github.get(MAIN), newer_main)

    def test_rewriting_a_branch_someone_else_changed_fails_and_leaves_their_work(self):
        mine = self.gitea.commit("pr")
        self.gitea.push(PR, mine)
        self.sync()
        theirs = self.github.commit("maintainer", parent=mine)
        self.github.push(PR, theirs)
        self.gitea.push(PR, self.gitea.commit("pr rewritten"))

        with self.assertRaisesRegex(RuntimeError, "refs/heads/pr"):
            self.sync()
        self.assertEqual(self.github.get(PR), theirs)

    def test_building_on_their_commit_in_gitea_resumes_mirroring(self):
        mine = self.gitea.commit("pr")
        self.gitea.push(PR, mine)
        self.sync()
        self.github.push(PR, self.github.commit("maintainer", parent=mine))
        self.sync()

        self.gitea.fetch(self.github, PR)
        follow_up = self.gitea.commit("follow-up", parent=self.gitea.get(PR))
        self.gitea.push(PR, follow_up)
        self.sync()

        self.assertEqual(self.github.get(PR), follow_up)

    def test_rewrites_and_deletions_in_gitea_reach_github_when_nobody_else_touched_the_ref(self):
        self.gitea.push(PR, self.gitea.commit("pr"))
        git(self.gitea.path, "tag", "-a", "-m", "v1", "v1", self.main)
        self.sync()

        rewritten = self.gitea.commit("pr amended")
        self.gitea.push(PR, rewritten)
        self.sync()
        self.assertEqual(self.github.get(PR), rewritten)

        self.gitea.delete(PR)
        self.gitea.delete("refs/tags/v1")
        self.sync()
        self.assertIsNone(self.github.get(PR))
        self.assertIsNone(self.github.get("refs/tags/v1"))

    def test_refs_written_only_on_github_are_never_deleted(self):
        self.sync()
        their_branch = self.github.commit("their branch", parent=self.main)
        self.github.push("refs/heads/theirs", their_branch)
        mine = self.gitea.commit("pr")
        self.gitea.push(PR, mine)
        self.sync()
        theirs = self.github.commit("maintainer", parent=mine)
        self.github.push(PR, theirs)

        self.gitea.delete(PR)
        self.sync()
        self.sync()

        self.assertEqual(self.github.get("refs/heads/theirs"), their_branch)
        self.assertEqual(self.github.get(PR), theirs)

    def test_first_sync_after_upgrade_keeps_commits_gitea_never_had(self):
        mine = self.gitea.commit("pr")
        self.gitea.push(PR, mine)
        self.gitea.push("refs/heads/wip", self.gitea.commit("wip"))
        self.legacy_sync()
        theirs = self.github.commit("maintainer", parent=mine)
        self.github.push(PR, theirs)
        rewritten_wip = self.gitea.commit("wip amended")
        self.gitea.push("refs/heads/wip", rewritten_wip)
        newer_main = self.gitea.commit("main 2", parent=self.main)
        self.gitea.push(MAIN, newer_main)

        self.sync()

        self.assertEqual(self.github.get(PR), theirs)
        self.assertEqual(self.github.get("refs/heads/wip"), rewritten_wip)
        self.assertEqual(self.github.get(MAIN), newer_main)


if __name__ == "__main__":
    unittest.main()

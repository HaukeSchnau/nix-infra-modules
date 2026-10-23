import fcntl
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


REFSPECS = [
    "+refs/heads/*:refs/heads/*",
    "+refs/tags/*:refs/tags/*",
]

# The mirror never fetches from GitHub. Git updates these refs after each
# successful push, so they record what the mirror itself last wrote there.
PUSHED_PREFIX = "refs/remotes/github/"
PUSHED_REFSPECS = {
    "refs/heads/": f"+refs/heads/*:{PUSHED_PREFIX}heads/*",
    "refs/tags/": f"+refs/tags/*:{PUSHED_PREFIX}tags/*",
}


def read_secret(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read().strip()


def quote_credential(value):
    return urllib.parse.quote(value, safe="")


def repo_parts(path):
    owner, sep, repo = path.partition("/")
    if not sep or not owner or not repo or "/" in repo:
        raise ValueError(f"expected owner/name repository path, got {path!r}")
    return owner, repo


def mirror_key(path):
    owner, repo = repo_parts(path)
    return f"{owner}__{repo}"


def repo_url(base_url, path):
    return f"{base_url.rstrip('/')}/{path}.git"


def repo_api_path(path):
    owner, repo = repo_parts(path)
    return f'/repos/{urllib.parse.quote(owner, safe="")}/{urllib.parse.quote(repo, safe="")}'


def gitea_visibility(repo):
    return "private" if repo.get("private", True) else "public"


def github_url(base_url, path):
    return f"{base_url.rstrip('/')}/{path}.git"


def credential_line(url, username, password):
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https":
        raise ValueError(f"credential store only supports https URLs, got {url!r}")
    return (
        f"https://{quote_credential(username)}:{quote_credential(password)}"
        f"@{parsed.netloc}\n"
    )


class Gitea:
    def __init__(self, base_url, api_base_url, token, user_agent):
        self.base_url = base_url.rstrip("/")
        self.api_base_url = (api_base_url or f"{self.base_url}/api/v1").rstrip("/")
        self.token = token
        self.user_agent = user_agent

    def request(self, path):
        request = urllib.request.Request(
            f"{self.api_base_url}{path}",
            headers={
                "Accept": "application/json",
                "Authorization": f"token {self.token}",
                "User-Agent": self.user_agent,
            },
            method="GET",
        )
        # A host activation that restarts Gitea can start this sync while Gitea is still coming up.
        for attempt in range(12):
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    data = response.read()
                break
            except urllib.error.HTTPError as error:
                message = error.read().decode("utf-8", errors="replace")
                if error.code in (502, 503, 504) and attempt < 11:
                    time.sleep(5)
                    continue
                raise RuntimeError(f"Gitea API GET {path} failed: HTTP {error.code}: {message}") from error
            except urllib.error.URLError:
                if attempt < 11:
                    time.sleep(5)
                    continue
                raise

        if not data:
            return {}
        return json.loads(data.decode("utf-8"))

    def list_repositories(self):
        repositories = []
        page = 1
        limit = 50
        while True:
            batch = self.request(f"/user/repos?limit={limit}&page={page}")
            if not isinstance(batch, list):
                raise RuntimeError("Gitea API /user/repos returned a non-list response")
            repositories.extend(batch)
            if len(batch) < limit:
                return repositories
            page += 1

    def get_repository(self, path):
        return self.request(repo_api_path(path))


class GitHub:
    def __init__(self, api_base_url, token, user_agent):
        self.api_base_url = api_base_url.rstrip("/")
        self.token = token
        self.user_agent = user_agent

    def request(self, method, path, payload=None, allow_not_found=False):
        body = None
        headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {self.token}",
            "User-Agent": self.user_agent,
            "X-GitHub-Api-Version": "2022-11-28",
        }
        if payload is not None:
            body = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"

        request = urllib.request.Request(
            f"{self.api_base_url}{path}",
            data=body,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                data = response.read()
        except urllib.error.HTTPError as error:
            if allow_not_found and error.code == 404:
                return None
            message = error.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"GitHub API {method} {path} failed: HTTP {error.code}: {message}") from error

        if not data:
            return {}
        return json.loads(data.decode("utf-8"))

    def ensure_repo(self, github_path, owner_type, visibility, description, create):
        owner, repo = repo_parts(github_path)
        existing = self.request("GET", f"/repos/{owner}/{repo}", allow_not_found=True)
        desired_private = visibility == "private"

        if existing is None:
            if not create:
                raise RuntimeError(f"GitHub repository {github_path} does not exist and create=false")

            payload = {
                "name": repo,
                "private": desired_private,
                "auto_init": False,
            }
            if description:
                payload["description"] = description

            if owner_type == "org":
                self.request("POST", f"/orgs/{owner}/repos", payload)
            else:
                self.request("POST", "/user/repos", payload)
            print(f"github: created {github_path} as {visibility}", flush=True)
            return

        patch = {}
        if bool(existing.get("private")) != desired_private:
            patch["private"] = desired_private
        if description is not None and existing.get("description") != description:
            patch["description"] = description
        if patch:
            self.request("PATCH", f"/repos/{owner}/{repo}", patch)
            print(f"github: updated {github_path}", flush=True)
        else:
            print(f"github: {github_path} already exists", flush=True)


def run_git(args, cwd, credential_file, check=True, quiet=False, capture=False, stdin=None):
    command = [
        "git",
        "-c",
        f"credential.helper=store --file={credential_file}",
        "-c",
        "gc.auto=0",
        *args,
    ]
    return subprocess.run(
        command,
        cwd=cwd,
        check=check,
        input=stdin,
        text=True,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL if quiet else None,
        stderr=subprocess.DEVNULL if quiet else None,
        env={
            **os.environ,
            "GIT_ASKPASS": "/bin/false",
            "GIT_TERMINAL_PROMPT": "0",
        },
    )


def resolve_repository(repo, defaults):
    source_path = repo.get("giteaPath") or repo["name"]
    _source_owner, source_repo = repo_parts(source_path)

    github_path = repo.get("githubPath")
    if not github_path:
        github_owner = repo.get("githubOwner") or defaults["githubOwner"]
        github_name = repo.get("githubName") or source_repo
        github_path = f"{github_owner}/{github_name}"
    repo_parts(github_path)

    return {
        "name": mirror_key(source_path),
        "giteaPath": source_path,
        "githubPath": github_path,
        "githubOwnerType": repo.get("githubOwnerType") or defaults["githubOwnerType"],
        "visibility": repo.get("giteaVisibility") or "private",
        "description": repo.get("description"),
        "create": repo.get("create", True),
        "empty": bool(repo.get("empty", False)),
    }


def resolve_repositories(cfg, gitea):
    excluded = set(cfg["excludeRepositories"])
    repositories = {}

    if cfg["mirrorAll"]:
        for repo in gitea.list_repositories():
            source_path = repo.get("full_name")
            if not source_path:
                raise RuntimeError("Gitea repository entry is missing full_name")
            repositories[source_path] = {
                "name": source_path,
                "giteaPath": source_path,
                "giteaVisibility": gitea_visibility(repo),
                "empty": bool(repo.get("empty", False)),
            }

    for repo in cfg["repositories"]:
        source_path = repo.get("giteaPath") or repo["name"]
        merged = {
            **repositories.get(source_path, {}),
            **repo,
            "giteaPath": source_path,
        }
        if "giteaVisibility" not in merged:
            gitea_repo = gitea.get_repository(source_path)
            merged["giteaVisibility"] = gitea_visibility(gitea_repo)
            merged["empty"] = bool(gitea_repo.get("empty", merged.get("empty", False)))
        repositories[source_path] = merged

    resolved = []
    seen_destinations = {}
    for source_path, repo in sorted(repositories.items()):
        if source_path in excluded:
            print(f"mirror/{source_path}: skipped by excludeRepositories", flush=True)
            continue
        mirror = resolve_repository(repo, cfg["defaults"])
        previous_source = seen_destinations.get(mirror["githubPath"])
        if previous_source is not None:
            raise RuntimeError(
                f"{source_path} and {previous_source} both resolve to GitHub repository {mirror['githubPath']}"
            )
        seen_destinations[mirror["githubPath"]] = source_path
        resolved.append(mirror)

    return resolved


def pushed_ref(ref):
    return PUSHED_PREFIX + ref.removeprefix("refs/")


def sync_repository(repo, cfg, state_dir, credential_file):
    name = repo["name"]
    source_url = repo_url(cfg["gitea"]["baseUrl"], repo["giteaPath"])
    destination_url = github_url(cfg["github"]["baseUrl"], repo["githubPath"])
    mirror_dir = os.path.join(state_dir, "repositories", f"{name}.git")

    def git(*args, **options):
        return run_git(list(args), cwd=mirror_dir, credential_file=credential_file, **options)

    def refs(*args):
        return {ref: sha for sha, ref in (line.split() for line in git(*args, capture=True).stdout.splitlines())}

    def record(pushed):
        git("update-ref", "--stdin", stdin="".join(
            f"update {pushed_ref(ref)} {sha}\n" if sha else f"delete {pushed_ref(ref)}\n"
            for ref, sha in pushed.items()
        ))

    print(f"mirror/{name}: syncing {repo['giteaPath']} -> {repo['githubPath']}", flush=True)
    if repo["empty"]:
        print(f"mirror/{name}: source repository is empty; GitHub repository exists", flush=True)
        return

    if not os.path.isdir(os.path.join(mirror_dir, "objects")):
        if os.path.exists(mirror_dir):
            shutil.rmtree(mirror_dir)
        os.makedirs(mirror_dir, exist_ok=True)
        run_git(
            ["init", "--bare", "--initial-branch=main", mirror_dir],
            cwd=None,
            credential_file=credential_file,
        )

    for remote, url in (("origin", source_url), ("github", destination_url)):
        exists = git("remote", "get-url", remote, check=False, quiet=True).returncode == 0
        git("remote", "set-url" if exists else "add", remote, url)
    for prefix, refspec in PUSHED_REFSPECS.items():
        git("config", "--replace-all", "remote.github.fetch", refspec, f"^\\+{prefix}")
    git("fetch", "--prune", "--prune-tags", "origin", *REFSPECS)

    each_ref = ("for-each-ref", "--format=%(objectname) %(refname)")
    gitea = refs(*each_ref, "refs/heads/", "refs/tags/")
    pushed = {"refs/" + ref.removeprefix(PUSHED_PREFIX): sha for ref, sha in refs(*each_ref, PUSHED_PREFIX).items()}
    github = refs("ls-remote", "--heads", "--tags", "--refs", "github")

    if not pushed:
        # Mirrors without this record force-pushed every ref. A GitHub ref at a
        # commit Gitea never had was pushed to GitHub directly, so the mirror
        # adopts Gitea's value as its own and leaves GitHub's in place.
        listing = git("cat-file", "--batch-check", capture=True, stdin="".join(f"{sha}\n" for sha in github.values()))
        unseen = {line.split()[0] for line in listing.stdout.splitlines() if line.endswith(" missing")}
        pushed = {ref: gitea.get(ref) if sha in unseen else sha for ref, sha in github.items()}
        pushed = {ref: sha for ref, sha in pushed.items() if sha}
        record(pushed)
        print(f"mirror/{name}: recorded {len(pushed)} GitHub refs as mirror-written", flush=True)

    adopted, updates, kept, conflicts = {}, {}, [], []
    for ref in sorted(gitea.keys() | pushed.keys()):
        want, last, have = gitea.get(ref), pushed.get(ref), github.get(ref)
        if have == want:
            if last != want:
                adopted[ref] = want
        elif want == last:
            kept.append(ref)
        elif have == last:
            updates[ref] = (want, have)
        elif want is None:
            kept.append(ref)
            adopted[ref] = None
        elif have is None or git("merge-base", "--is-ancestor", have, want, check=False, quiet=True).returncode == 0:
            updates[ref] = (want, have)
        else:
            conflicts.append(ref)

    if adopted:
        record(adopted)
    for ref in kept:
        print(f"mirror/{name}: kept {ref}, which changed on GitHub since the mirror last pushed it", flush=True)

    problems = []
    if updates:
        leases = [f"--force-with-lease={ref}:{have or ''}" for ref, (_want, have) in updates.items()]
        refspecs = [f"{ref}:{ref}" if want else f":{ref}" for ref, (want, _have) in updates.items()]
        if git("push", *leases, "github", *refspecs, check=False).returncode != 0:
            problems.append("GitHub rejected part of the push")
    if conflicts:
        problems.append(f"changed on both Gitea and GitHub since the mirror last pushed: {', '.join(conflicts)}")
    if problems:
        raise RuntimeError("; ".join(problems))
    print(f"mirror/{name}: ok", flush=True)


def main():
    config_file = os.environ["GIT_MIRRORS_CONFIG"]
    state_dir = os.environ["GIT_MIRRORS_STATE_DIR"]
    runtime_dir = os.environ["GIT_MIRRORS_RUNTIME_DIR"]

    with open(config_file, "r", encoding="utf-8") as handle:
        cfg = json.load(handle)

    gitea_token = read_secret(os.environ["GIT_MIRRORS_GITEA_TOKEN_FILE"])
    github_token = read_secret(os.environ["GIT_MIRRORS_GITHUB_TOKEN_FILE"])

    os.makedirs(os.path.join(state_dir, "repositories"), exist_ok=True)
    os.makedirs(runtime_dir, exist_ok=True)

    lock_path = os.path.join(state_dir, "sync.lock")
    with open(lock_path, "w", encoding="utf-8") as lock_handle:
        fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)

        credential_file = os.path.join(runtime_dir, "credentials")
        try:
            with open(credential_file, "w", encoding="utf-8") as handle:
                handle.write(credential_line(cfg["gitea"]["baseUrl"], cfg["gitea"]["username"], gitea_token))
                handle.write(credential_line(cfg["github"]["baseUrl"], "x-access-token", github_token))
            os.chmod(credential_file, 0o600)

            gitea = Gitea(cfg["gitea"]["baseUrl"], cfg["gitea"]["apiBaseUrl"], gitea_token, cfg["userAgent"])
            github = GitHub(cfg["github"]["apiBaseUrl"], github_token, cfg["userAgent"])
            repositories = resolve_repositories(cfg, gitea)
            failures = []
            for repo in repositories:
                try:
                    github.ensure_repo(
                        repo["githubPath"],
                        repo["githubOwnerType"],
                        repo["visibility"],
                        repo["description"],
                        repo["create"],
                    )
                    sync_repository(repo, cfg, state_dir, credential_file)
                except Exception as error:
                    failures.append((repo["name"], str(error)))
                    print(f"mirror/{repo['name']}: failed: {error}", file=sys.stderr, flush=True)

            if failures:
                print("git-mirrors: failures:", file=sys.stderr, flush=True)
                for name, message in failures:
                    print(f"- {name}: {message}", file=sys.stderr, flush=True)
                return 1

            print(f"git-mirrors: synced {len(repositories)} repositories", flush=True)
            return 0
        finally:
            try:
                os.remove(credential_file)
            except FileNotFoundError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())

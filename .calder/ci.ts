import { Calder, On } from "@calder-ci/core";
import { Npm, Pnpm, Project, Vp } from "@calder-ci/std";
import { flake } from "./flake.ts";

const shell = flake.devShells.default;

const install = Pnpm.install({ shell });
const gate = Vp.tasks({ shell, setup: install });
const standard = Project.standard({ flake, checks: gate });

/**
 * A commit that raises `@schnau/tsconfig`'s version stages it on npm. npm accepts tokenless publishing
 * only from GitHub, GitLab.com and CircleCI, so a maintainer approves each staged release with 2FA.
 */
const tsconfig = Npm.publish({
  shell: flake.devShells.release,
  setup: install,
  token: "npm",
  dir: "packages/tsconfig",
  name: "publish-tsconfig",
  after: gate,
});

export default Calder.project({ rules: [...standard.rules, On.push("main", [tsconfig])] });

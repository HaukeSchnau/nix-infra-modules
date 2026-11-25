import { Calder, Flake, Nix, On } from "@calder-ci/core";
import { Npm, Pnpm, Project, Vp } from "@calder-ci/std";
import { flake } from "./flake.ts";

const shell = flake.devShells.default;

/**
 * The NixOS VM tests among the flake's checks. They need a builder with `kvm`, which the fleet has
 * for x86_64-linux only, so they build for that system; every other check builds for the
 * controller's. Add a new VM test here.
 */
const vmTests = new Set(["service-controller"]);
const checks = Object.fromEntries(
  Object.entries(flake.checks).filter(([name]) => !vmTests.has(name)),
);
const vms = [...vmTests].map((name) =>
  Nix.build(Flake.attr(`checks.x86_64-linux.${name}`), { name }),
);

const install = Pnpm.install({ shell });
const gate = [...vms, ...Vp.tasks({ shell, setup: install })];
const standard = Project.standard({ flake: { ...flake, checks }, checks: gate });

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

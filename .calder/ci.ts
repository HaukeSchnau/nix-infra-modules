import { Files, Flake, Nix, Task, cmd } from "@calder-ci/core"
import { Pnpm, Project } from "@calder-ci/std"
import { flake } from "./flake.ts"

const shell = flake.devShells.default
const fleet = "packages/fleet"

/**
 * The NixOS VM tests among the flake's checks. They need a builder with `kvm`, which the fleet has
 * for x86_64-linux only, so they build for that system; every other check builds for the
 * controller's. Add a new VM test here.
 */
const vmTests = new Set(["service-controller"])
const checks = Object.fromEntries(Object.entries(flake.checks).filter(([name]) => !vmTests.has(name)))
const vms = [...vmTests].map((name) => Nix.build(Flake.attr(`checks.x86_64-linux.${name}`), { name }))

/** `@schnau/fleet` has no tests, so its types are what this checks. */
const typecheck = Task.make("fleet-typecheck", {
  shell,
  setup: Pnpm.install({ shell, dir: fleet }),
  inputs: Files.of(fleet),
  run: cmd`pnpm --dir ${fleet} typecheck`,
})

export default Project.standard({ flake: { ...flake, checks }, checks: [...vms, typecheck] })

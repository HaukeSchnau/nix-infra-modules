import { antipattern, correctness, style } from "@effect/tsgo/oxlint-presets";
import { defineConfig } from "vite-plus";

const errors = (rules: ReadonlyArray<string>) =>
  Object.fromEntries(rules.map((rule): [string, "error"] => [rule, "error"]));

const effectRules = [correctness, antipattern, style].flatMap((preset) =>
  Object.keys(preset.rules ?? {}),
);

export default defineConfig({
  fmt: {
    ignorePatterns: [
      // Vendored as upstream wrote it, so the next update is a plain copy.
      "tools/oxlint/anti-slop/**",
    ],
    sortPackageJson: {},
  },
  test: {
    // The workspace holds configuration only.
    passWithNoTests: true,
  },
  lint: {
    ignorePatterns: [
      // Calder's own TypeScript project, with a tsconfig package the workspace doesn't install.
      ".calder",
      // Vendored as upstream wrote it; upstream lints and tests it.
      "tools/oxlint/anti-slop",
    ],
    plugins: ["effecttsgo", "eslint", "import", "oxc", "typescript", "unicorn"],
    jsPlugins: [
      { name: "anti-slop", specifier: "./tools/oxlint/anti-slop/index.ts" },
      { name: "anti-slop-effect", specifier: "./tools/oxlint/anti-slop/effect/index.ts" },
    ],
    categories: {
      correctness: "error",
      perf: "error",
      suspicious: "error",
    },
    rules: {
      ...errors(effectRules),

      "eslint/eqeqeq": "error",
      "typescript/consistent-type-imports": "error",
      "typescript/no-explicit-any": "error",
      "typescript/no-non-null-assertion": "error",
      "unicorn/prefer-node-protocol": "error",

      "oxc/no-accumulating-spread": "error",
      "anti-slop/no-array-filter-map": "error",
      "anti-slop/no-reduce-accumulator-copy": "error",
      "anti-slop/no-chained-type-assertions": "error",
      "anti-slop/no-conditional-empty-object-spread": "error",
      "anti-slop/no-known-value-widening": "error",
      "anti-slop/no-module-mocking": "error",
      "anti-slop/no-object-parameters": "error",
      "anti-slop/no-reflect-apply": "error",
      "anti-slop/no-reflect-get": "error",
      "anti-slop/no-runtime-typeof": "error",
      "anti-slop/no-shape-in-symbol-names": "error",
      "anti-slop/no-unknown-parameters": "error",
      "anti-slop/no-unknown-returns": "error",
      "anti-slop/no-unknown-type-aliases": "error",
      "anti-slop/no-unsafe-dictionary-type": "error",
      "anti-slop/no-widen-then-assert": "error",
      "anti-slop/require-readable-spacing": "error",
      "anti-slop/require-safety-comment-for-type-assertion": "error",
      "anti-slop-effect/no-manual-effect-error-tag": "error",
      "anti-slop-effect/no-manual-tag-comparison": "error",
      "anti-slop-effect/no-manual-tagged-construction": "error",
      "anti-slop-effect/no-service-constructor-imports": "error",
      "anti-slop-effect/prefer-effect-match": "error",
    },
    options: {
      typeAware: true,
      typeCheck: true,
    },
  },
});

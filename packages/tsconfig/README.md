# @schnau/tsconfig

The base tsconfig for TypeScript that Node runs from source and the native compiler (TypeScript 7,
tsrs) checks. It holds compiler options only. A repository adds its platform: `types`, DOM libs,
`jsx`, `expo/tsconfig.base`.

```jsonc
// tsconfig.json
{
  "extends": "@schnau/tsconfig",
  "compilerOptions": { "types": ["node"] },
}
```

| Entry point               | Adds                                        |
| ------------------------- | ------------------------------------------- |
| `@schnau/tsconfig`        | nothing, it is the base                     |
| `@schnau/tsconfig/effect` | the `@effect/language-service` plugin entry |

The plugin entry turns on Effect's language service: its quick info, completions and refactors in
the editor. Its `diagnostics` are off, because oxlint's `effecttsgo` rules report the same
diagnostics, and a repository picks their severities in `vite.config.ts`. With them on, the tsrs
that `effect-tsgo patch --tsrs` patches reports each one a second time as a type error, in
`vp check` and in every `tsrs -p` build, where an Effect warning fails the build.

The stock compilers (`tsc`, TypeScript 7, tsrs) ignore plugins, so the entry costs nothing where
effect-tsgo isn't installed. It still stays out of the base: a repository without Effect shouldn't
switch Effect's rules on, and `plugins` replaces the inherited list, so a repository with a plugin
of its own would have to repeat Effect's.

`exactOptionalPropertyTypes` is off on purpose. It forces `...(x === undefined ? {} : { x })`
spreads into every option object and React prop.

## Platforms

- TypeScript 7 defaults `types` to `[]`, so a repository names the globals it uses: `["node"]`,
  `["bun"]`, or none in a browser app, which sets `"lib": ["ESNext", "DOM", "DOM.Iterable"]`.
- An Expo app extends both, Expo last, so Expo's `lib`, `jsx` and `customConditions` win:
  `"extends": ["@schnau/tsconfig", "expo/tsconfig.base"]`.
- A library that emits JavaScript turns `noEmit` off and rewrites its `.ts` imports, which
  `allowImportingTsExtensions` requires once it emits:

  ```jsonc
  {
    "extends": "@schnau/tsconfig",
    "compilerOptions": {
      "noEmit": false,
      "declaration": true,
      "rewriteRelativeImportExtensions": true,
      "rootDir": "src",
      "outDir": "dist",
    },
  }
  ```

## Install

The package is on npm:

```sh
pnpm add -D @schnau/tsconfig
```

A `deploy/` package that maps the `@schnau` scope to the Gitea registry for `@schnau/fleet` gets the
same versions from there (`https://git.schnau.dev/api/packages/schnau/npm/`).

pnpm 11 and later install a version only a day after its release (`minimumReleaseAge`). Our own
package can skip the wait:

```yaml
# pnpm-workspace.yaml
minimumReleaseAgeExclude:
  - "@schnau/tsconfig"
```

## Publish

Raise `version` and merge it. Calder's `publish-tsconfig` step then stages the release on npm, and a
maintainer approves it with 2FA (`npm stage approve <stage>`; the step's log names the stage).

The Gitea registry is published by hand from a clean checkout of `main`, with a token that may write
packages in your user `.npmrc` (`//git.schnau.dev/api/packages/schnau/npm/:_authToken=<token>`):

```sh
pnpm publish --no-git-checks --registry https://git.schnau.dev/api/packages/schnau/npm/
```

jj leaves Git's HEAD detached, which pnpm's branch check rejects outside CI, hence `--no-git-checks`.

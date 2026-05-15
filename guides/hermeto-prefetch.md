# Using Hermeto to Prefetch Dependencies for Hermetic Konflux Builds

## What is Hermeto

Hermeto is a CLI tool that pre-fetches project dependencies so that container builds can run without network access (hermetic builds). It downloads all declared dependencies from lockfiles into a local output directory, generates an SBOM, and produces environment files that configure package managers to use the local cache instead of reaching out to the internet. Hermeto is the renamed successor of Cachi2 -- the output directory and environment file in this guide (and in konflux) still use the `/cachi2/` paths for backward compatibility.

In a Konflux pipeline, setting `hermetic: true` in your PipelineRun cuts network access during the build step -- the equivalent of `podman build --network none`. Without prefetched dependencies, any `pip install`, `go build`, `npm ci`, or `dnf install` in your Dockerfile will fail because it cannot reach the internet. Hermeto's job is to download everything ahead of time so the build succeeds without network access.

## Installing Hermeto

The easiest way to run hermeto locally is through its container image. Set up a shell alias so you can use `hermeto` as if it were installed natively:

```bash
alias hermeto='podman run --rm -ti -v "$PWD:$PWD:z" -w "$PWD" \
  ghcr.io/hermetoproject/hermeto:latest'
```

The `-v "$PWD:$PWD:z"` flag bind-mounts your project directory into the container so hermeto can read your lockfiles and write output, and `-w "$PWD"` sets the working directory to match. All `hermeto` commands in this guide assume this alias is in place.

## Quick Start

If your project uses a single package manager with standard lockfiles, the path is short:

1. Read your Dockerfile and identify every network access point (pip install, go build, npm ci, dnf install, curl/wget)
2. Write a `hermeto-test.json` config — jump to your package manager: [pip](#pip-python) | [gomod](#gomod-go) | [npm](#npm-javascript) | [cargo](#cargo-rust)
3. Run `hermeto fetch-deps`, fix issues, repeat until it passes — see [Building with Prefetched Dependencies](#building-with-prefetched-dependencies)
4. Test with `podman build --network none` — see [Test locally with a hermetic build](#4-test-locally-with-a-hermetic-build)
5. Copy the JSON config into your `.tekton/` PipelineRun `prefetch-input` parameter — see [What to Commit](#what-to-commit)

For **Go** and **npm** projects, the config is often a one-liner (`{"type": "gomod", "path": "."}`) and you can skip most of the guide. The bulk of this guide covers **Python/AIPCC** and **RPM** workflows, which have significantly more complexity.

> **Do not commit `. /cachi2/cachi2.env` sourcing into your Dockerfile.konflux.** The Konflux build pipeline [automatically injects](https://github.com/konflux-ci/build-definitions/blob/44ffba6bd5e8a3da0511b13677b3a0982ae6722e/task/buildah-oci-ta/0.8/buildah-oci-ta.yaml#L749-L754) `. /cachi2/cachi2.env &&` before every `RUN` instruction at build time using a sed transform. The local testing steps in this guide replicate that injection for `podman build` — do not check those changes into your committed Dockerfile.konflux.

## Recommended Workflow

### Create a Dockerfile.konflux

Start by copying your existing Dockerfile (or `Containerfile`, if your project uses the Podman naming convention) to `Dockerfile.konflux`. This is the copy you will modify for hermetic builds -- keep the original untouched so the project's existing non-hermetic build continues to work.

```bash
cp Dockerfile Dockerfile.konflux    # or: cp Containerfile Dockerfile.konflux
```

All subsequent changes in this guide (sourcing the hermeto env file, adding system packages to support hermetic installs, etc.) should be made in `Dockerfile.konflux`.

### Start from the Dockerfile

The Dockerfile is the source of truth for what the build needs. Before writing any hermeto config, read through the Dockerfile (and any scripts it COPYs and RUNs) and identify every point where the build pulls something from the network:

- **Package manager installs** -- pip, cargo, npm, go, yarn, bundler
- **System package installs** -- microdnf, dnf, yum
- **Direct downloads** -- curl, wget, git clone, or any script that fetches from the internet. These can often be handled with the [generic fetcher](#generic). Alternatively, you can eliminate the download entirely: copy the binary from an existing, trusted container image via a multi-stage `COPY --from=` (e.g., kubectl from `ose-cli-rhel9`), choose a base image that already includes the tools you need, add the tool's source as a git submodule and build it from source with its own prefetch entry, or pre-commit the assets to the repo via a separate CI workflow (e.g., a GitHub Action that clones upstream repos, downloads artifacts, or runs an external build system like PNC, then commits the results so the Dockerfile can simply `COPY` them).

> **Red Hat note:** Generic fetcher entries require a policy exception for productized builds. Prefer the alternatives above (multi-stage copy, base image selection, building from source) when possible.

Each network access point maps to a hermeto package manager config (see [Configuring hermeto-test.json](#configuring-hermeto-testjson)) or needs a manual workaround.

Only network access in the Dockerfile matters. A repo may contain lockfiles (e.g., `package-lock.json` for a documentation site, or `requirements.txt` for a test suite) that are never referenced by the container build -- these do not need hermeto entries. The Dockerfile is your guide, not the repo's file listing.

Multiple commands using the same package manager still map to a single hermeto entry. For example, a Dockerfile might run `npm ci` for a full install during the build stage and then `npm install --omit=dev` to prune to production dependencies. Both draw from the same prefetched cache -- hermeto prefetches everything in the lockfile, and each `npm` command finds what it needs regardless of flags like `--omit=dev` or `--ignore-scripts`.

If the project has multiple Dockerfiles, identify which one is the target for hermetic builds. Also check whether the Dockerfile requires additional build inputs (argfiles, build-args, `.env` files) that affect what gets installed.[^no-deps]

[^no-deps]: If your analysis finds zero network access points, you don't need hermeto at all. Set `hermetic: true` in your pipeline without `prefetch-input` — the build succeeds with nothing to prefetch. This is common for data-only containers that just COPY static files into the image.

### Iterate one package manager at a time

Getting a hermetic build working is an iterative process. The core loop for each package manager is:

1. Add the manager to `hermeto-test.json` -- start with the simplest valid config (just `type` and `path`), then add options as needed (e.g., `binary` for wheels, `requirements_build_files` for sdists)
2. Run `hermeto fetch-deps` -- expect this to fail at first while you refine the config
3. Fix issues (missing lockfiles, wrong options, version mismatches) and re-run until fetch-deps succeeds
4. Run a build to verify the prefetched deps actually work

You can work through package managers one at a time rather than configuring everything upfront. This works because some managers (like pip) use the prefetched cache automatically once the hermeto env vars are injected into the Dockerfile -- so you can run `podman build --network none` to verify that *the current manager* is fully hermetic while other managers (like RPMs) still use the network. Once one manager is confirmed hermetic, move on to the next.

Alternatively, you can configure all managers in `hermeto-test.json` first, get `fetch-deps` passing for everything, and then do a single full hermetic build at the end. Choose whichever approach suits the complexity of your project.

## Configuring `hermeto-test.json`

> **`hermeto-test.json` is for local testing only.** You do not commit this file. Once your hermetic build works locally, copy the JSON contents into the `prefetch-input` parameter of the prefetch task in your `.tekton/` PipelineRun YAML. See [What to Commit](#what-to-commit) for the full checklist.

The hermeto config is a JSON array of package manager objects, each with a `type` field and manager-specific options. For single-manager configs, the pipeline also accepts a bare JSON object (e.g., `{"type": "gomod", "path": "."}`) without the array wrapper.

**`path` is relative to the repo root, not to `path-context`.** In a Konflux pipeline, the `path-context` parameter sets the Docker build context directory, and the `dockerfile` parameter locates the Dockerfile relative to that context. The `path` field in the hermeto config is independent — it is always relative to the repo root (where hermeto's `--source` points). For subdirectory builds, these often have the same value (e.g., `path-context: ray-operator` and `"path": "ray-operator"`), but they serve different purposes and can diverge.

Hermeto supports the following package managers -- jump to the one(s) your project uses:

| Type | Language | Section |
|------|----------|---------|
| `pip` | Python | [pip (Python)](#pip-python) |
| `cargo` | Rust | [cargo (Rust)](#cargo-rust) |
| `gomod` | Go | [gomod (Go)](#gomod-go) |
| `npm` | JavaScript | [npm (JavaScript)](#npm-javascript) |
| `yarn` | JavaScript | [yarn (JavaScript)](#yarn-javascript) |
| `bundler` | Ruby | [bundler (Ruby)](#bundler-ruby) |
| `rpm` | System packages | [rpm](#rpm) |
| `generic` | Any (URLs, Maven) | [generic](#generic) |

A typical multi-manager config:

```json
[
  {
    "type": "pip",
    "path": ".",
    "requirements_files": ["requirements.txt"],
    "requirements_build_files": ["requirements-build.txt"],
    "binary": {
      "arch": "x86_64,aarch64,ppc64le,s390x"
    }
  },
  {
    "type": "rpm",
    "path": "."
  }
]
```

Once you have your config, use `hermeto fetch-deps` to download all the dependencies it defines:

```bash
hermeto fetch-deps \
  --source . \
  --output .hermeto \
  hermeto-test.json
```

Once `fetch-deps` is used to download the dependencies, some additional configuration is needed to actually get a local offline build working. See [Building with Prefetched Dependencies](#building-with-prefetched-dependencies) for how to properly use the prefetched output in a hermetic build.

### pip (Python)

[Hermeto pip docs](https://hermetoproject.github.io/hermeto/latest/pip/)

Hermeto requires a fully resolved `requirements.txt` with all transitive dependencies pinned to exact versions (e.g., `package==1.2.3`). Hashes are optional but recommended for PyPI packages, and mandatory for HTTPS URL dependencies. If any of your dependencies are sdists (no pre-built wheel available), you also need a `requirements-build.txt` listing their PEP 517 build backends. See the [Python guide](hermeto-python.md#python-requirements) for how to generate these files.

Some packages lack wheels or sdists on PyPI for certain architectures -- this is common on ppc64le and s390x. See the [Python guide's AIPCC section](hermeto-python.md#using-aipcc-wheels) to review how to leverage pre-built wheels, or [Building from Source](hermeto-python.md#building-from-source-for-missing-architectures) for how to build packages like torch from source tarballs.

**Config fields:**

| Field | Default | Description |
|-------|---------|-------------|
| `path` | `"."` | Directory containing requirements files, relative to `--source` |
| `requirements_files` | `["requirements.txt"]` | List of pinned requirements files (see the [Python guide](hermeto-python.md#python-requirements)) |
| `requirements_build_files` | `["requirements-build.txt"]` or `[]` | Build backend dependencies for sdists (see the [Python guide](hermeto-python.md#python-requirements)). Defaults to `["requirements-build.txt"]` if the file exists, `[]` otherwise |
| `binary` | *(omitted = sdists only)* | Binary wheel filter (see below) |

**Example — minimal:**

```json
{"type": "pip", "path": ".", "requirements_files": ["requirements.txt"]}
```

**Example — with binary wheels and build deps:**

```json
{
  "type": "pip",
  "path": ".",
  "requirements_files": ["requirements.txt"],
  "requirements_build_files": ["requirements-build.txt"],
  "binary": {
    "arch": "x86_64,aarch64,ppc64le,s390x"
  }
}
```

#### Binary wheel filtering

By default, hermeto fetches only source distributions (sdists). Add a `binary` object to download prebuilt wheels instead. This avoids needing Rust/C toolchains at build time for packages like `pydantic-core` or `cryptography`.

The key fields are `packages` (comma-separated names, or `:all:` to try wheels for everything), `arch` (comma-separated architectures, default `"x86_64"`), and `os` (default `"linux"`). When `packages` is `:all:` (the default), hermeto prefers wheels but falls back to sdists. When you name specific packages, hermeto *fails* if no matching wheel exists. See the [hermeto pip docs](https://hermetoproject.github.io/hermeto/latest/pip/) for additional filter fields (`py_version`, `py_impl`, `abi`, `platform`).

An empty `"binary": {}` is valid and uses all defaults (`packages: ":all:"`, `arch: "x86_64"`). This is the simplest way to enable wheel fetching, but it only fetches x86_64 wheels. To fetch wheels for all your target architectures, list them explicitly in `arch`.

`requirements_build_files` is needed if any of your dependencies are installed from source distributions (sdists) -- the build file provides the build backends (hatchling, maturin, etc.) needed to compile them.

If a package has no wheel for your target architecture on PyPI (common on ppc64le/s390x), you have two options:

1. **Use a custom index** like AIPCC that publishes prebuilt wheels for all architectures (see [Using AIPCC wheels](hermeto-python.md#using-aipcc-wheels)). This is the preferred approach -- hermeto handles arch selection at download time, so one requirements file works for all architectures.
2. **Build from source** by prefetching the source tarball through `requirements_build_files` alongside the build backends needed to compile it. Pip will use PyPI wheels where available and fall back to the source tarball on architectures that lack wheels. See [Building from source for missing architectures](hermeto-python.md#building-from-source-for-missing-architectures) for a worked example.

### cargo (Rust)

[Hermeto cargo docs](https://hermetoproject.github.io/hermeto/latest/cargo/)

Requires `Cargo.toml` and `Cargo.lock` to be present and in sync. The Cargo binary must be installed locally (or in the hermeto container).

**Config fields:**

| Field | Default | Description |
|-------|---------|-------------|
| `path` | `"."` | Directory containing `Cargo.toml`, relative to `--source` |

**Example:**

```json
{"type": "cargo", "path": "."}
```

After fetching, run `hermeto inject-files` to generate `.cargo/config.toml`, which redirects Cargo to the local vendor directory.

### gomod (Go)

[Hermeto gomod docs](https://hermetoproject.github.io/hermeto/latest/gomod/)

Requires `go.mod` and `go.sum`.

**Config fields:**

| Field | Default | Description |
|-------|---------|-------------|
| `path` | `"."` | Directory containing `go.mod`, relative to `--source` |

**Example:**

```json
{"type": "gomod", "path": "."}
```

Go projects are often the simplest case for hermetic builds — the `gomod` prefetch combined with the pipeline's automatic `cachi2.env` injection is usually sufficient with no Dockerfile.konflux modifications. If your Go project has no other network access points (no `npm`, `pip`, `microdnf install`, `curl`, etc.), you may only need the Konflux-general changes (base image pinning, labels) and a single `{"type": "gomod"}` prefetch entry.

**Vendor builds:** If your Dockerfile runs `go mod vendor` and builds with `-mod=vendor`, this works seamlessly with the prefetched cache — no extra configuration needed. The pipeline's `cachi2.env` sets `GOMODCACHE` to point at the prefetched dependencies, so `go mod vendor` copies from the prefetched cache into the local `vendor/` directory, and `go build -mod=vendor` uses it from there.

**`-mod=mod` builds:** If your Dockerfile sets `GOFLAGS=-mod=mod` or passes `-mod=mod` to `go build`, this also works with the prefetched cache. Go reads from the local `GOMODCACHE` without network access — the flag controls how Go resolves modules, not where it fetches them from.

**Removing `go mod download`:** If the upstream Dockerfile has an explicit `go mod download` step, remove it from Dockerfile.konflux. In a hermetic build, the pipeline's `cachi2.env` sets `GOMODCACHE` to the prefetched cache, so `go build` finds all dependencies without a separate download step. Leaving `go mod download` in place is harmless (it resolves from the local cache, not the network) but is dead code. If you see the older Cachito conditional pattern (`if [ -z ${CACHITO_ENV_FILE} ]; then go mod download; ...`), replace the entire block with just the `go build` command.

**Multi-module repos with Go workspaces:** If your repo contains multiple Go modules (separate `go.mod` files), check whether they're joined by a [`go.work`](https://go.dev/doc/tutorial/workspaces) file. When a `go.work` exists at the workspace root, Go tooling unifies the dependency graph across all workspace modules. A single `{"type": "gomod", "path": "."}` entry pointing at the workspace root is sufficient — hermeto's Go tooling respects the workspace and prefetches dependencies for all included modules.

**Multi-module repos with `replace` directives:** If the root `go.mod` uses `replace` directives to point at local submodules (e.g., `replace github.com/org/repo/api => ./api`), a single gomod entry at the root is also sufficient — Go resolves the local modules through the replacement path, so hermeto prefetches all external dependencies in one pass. This is common in operator repos where an `api/` submodule is consumed by the main module.

External `replace` directives that rewrite one remote module to another (e.g., `replace sigs.k8s.io/upstream => github.com/org/fork v1.0.0`) are also transparent to hermeto — it prefetches the replacement module as part of the normal dependency graph. These are common in RHOAI repos that fork upstream modules. A single gomod entry still suffices.

Without `go.work` or `replace` directives, each module needs its own gomod entry:

```json
[
  {"type": "gomod", "path": "."},
  {"type": "gomod", "path": "submodule"}
]
```

Run `find . -name go.mod -not -path '*/vendor/*'` to locate all Go modules. If they share most dependencies, consider adding a `go.work` file or a `replace` directive to simplify the prefetch config to a single entry.

### npm (JavaScript)

[Hermeto npm docs](https://hermetoproject.github.io/hermeto/latest/npm/)

Requires `package.json` and `package-lock.json`.

**Config fields:**

| Field | Default | Description |
|-------|---------|-------------|
| `path` | `"."` | Directory containing `package.json`, relative to `--source` |

**Example:**

```json
{"type": "npm", "path": "."}
```

**Monorepos with npm workspaces:** If your project uses [npm workspaces](https://docs.npmjs.com/cli/v10/using-npm/workspaces), a single entry pointing at the workspace root is sufficient -- npm workspaces share a single root `package-lock.json` that covers all workspace packages.

**Monorepos with independent sub-projects:** Hermeto does not auto-detect lockfiles. If your monorepo contains sub-projects with their own `package-lock.json` outside the workspace tree (common when packages have a separately-installed `frontend/` directory), each one needs its own npm entry:

```json
[
  {"type": "npm", "path": "."},
  {"type": "npm", "path": "packages/mymod/frontend"}
]
```

Run `find . -name package-lock.json -not -path '*/node_modules/*'` to find all lockfiles that may need entries.

> **Note:** `npm ci --ignore-scripts` and `npm install --ignore-scripts` work correctly with prefetch. The `--ignore-scripts` flag skips lifecycle scripts (preinstall, postinstall, etc.) and is a good security practice for container builds since it prevents arbitrary code execution during dependency installation.

### yarn (JavaScript)

[Hermeto yarn docs](https://hermetoproject.github.io/hermeto/latest/yarn/)

Supports Yarn versions 1, 3, and 4.

**Config fields:**

| Field | Default | Description |
|-------|---------|-------------|
| `path` | `"."` | Directory containing `package.json`, relative to `--source` |
| `workspaces` | *(none)* | List of workspace names for monorepo projects |

**Example:**

```json
{"type": "yarn", "path": "."}
```

**Example — with workspaces:**

```json
{"type": "yarn", "path": ".", "workspaces": ["packages/ui", "packages/api"]}
```

### bundler (Ruby)

[Hermeto bundler docs](https://hermetoproject.github.io/hermeto/latest/bundler/)

Requires `Gemfile` and `Gemfile.lock`.

**Config fields:**

| Field | Default | Description |
|-------|---------|-------------|
| `path` | `"."` | Directory containing `Gemfile`, relative to `--source` |

**Example:**

```json
{"type": "bundler", "path": "."}
```

### rpm

[Hermeto rpm docs](https://hermetoproject.github.io/hermeto/latest/rpm/)

Prefetches system RPM packages. Requires an `rpms.lock.yaml` lockfile (see [RPM Dependencies](#rpm-dependencies) below for how to generate it).

**Config fields:**

| Field | Default | Description |
|-------|---------|-------------|
| `path` | `"."` | Directory containing `rpms.lock.yaml`, relative to `--source` |

**Example:**

```json
{"type": "rpm", "path": "."}
```

### generic

[Hermeto generic docs](https://hermetoproject.github.io/hermeto/latest/generic/)

Downloads arbitrary files or Maven artifacts by URL. Use this for dependencies that don't fit any other package manager -- for example, files fetched with `curl` or `wget` in the Dockerfile. Avoid using it for anything already supported by a dedicated hermeto package manager, since the SBOM entries it produces are less accurate.

Dependencies are declared in an `artifacts.lock.yaml` lockfile rather than in `hermeto-test.json` options:

```yaml
metadata:
  version: "1.0"
artifacts:
  # Arbitrary file download
  - download_url: "https://example.com/some-tool-v1.2.tar.gz"
    filename: "some-tool.tar.gz"
    checksum: "sha256:abc123..."

  # Maven artifact
  - type: "maven"
    filename: "ant.jar"
    attributes:
      repository_url: "https://repo1.maven.org/maven2"
      group_id: "org.apache.ant"
      artifact_id: "ant"
      version: "1.10.14"
      type: "jar"
    checksum: "sha256:4cbbd9243de4c1042d61d9a15db4c43c90ff93b16d78b39481da1c956c8e9671"
```

Each artifact requires a `checksum` in `algorithm:hash` format. Downloaded files are stored in `deps/generic/` within the output directory — at build time, the full path is `/cachi2/output/deps/generic/<filename>`.

**Architecture-specific artifacts:** The generic fetcher does not support architecture variables in URLs or filenames — each entry is a literal download. For tools that publish per-arch binaries (e.g., kubectl, oc, helm), add a separate entry for each target architecture and use the Dockerfile's `${TARGETARCH}` variable to select the right file at build time:

```yaml
artifacts:
  - download_url: "https://mirror.openshift.com/.../openshift-client-linux-amd64-rhel9-4.21.15.tar.gz"
    filename: "openshift-client-linux-amd64-rhel9-4.21.15.tar.gz"
    checksum: "sha256:1fa80bbf..."
  - download_url: "https://mirror.openshift.com/.../openshift-client-linux-arm64-rhel9-4.21.15.tar.gz"
    filename: "openshift-client-linux-arm64-rhel9-4.21.15.tar.gz"
    checksum: "sha256:fb7bccab..."
```

```dockerfile
# In a builder stage (ubi-minimal lacks tar):
RUN tar -xzf /cachi2/output/deps/generic/openshift-client-linux-${TARGETARCH}-rhel9-4.21.15.tar.gz \
    -C /tmp/ kubectl && \
    mv /tmp/kubectl /usr/local/bin/kubectl
```

Hermeto downloads all entries regardless of the current build architecture, so each arch build finds its matching file. Keep the lockfile entries aligned with your pipeline's `build-platforms` — if you add ppc64le or s390x later, you need corresponding entries in `artifacts.lock.yaml`. See [ai-gateway-payload-processing](https://github.com/red-hat-data-services/ai-gateway-payload-processing/blob/rhoai-3.5-ea.1/artifacts.lock.yaml) for a working example.

**Config fields:**

| Field | Default | Description |
|-------|---------|-------------|
| `path` | `"."` | Directory containing the lockfile, relative to `--source` |
| `lockfile` | `"artifacts.lock.yaml"` | Path to the artifacts lockfile |

**Example:**

```json
{"type": "generic", "path": "."}
```

**Java/Maven projects:** Hermeto has no native Maven package manager type. For Red Hat productized Java builds, the typical pattern is to build the artifact externally using [PNC](https://github.com/project-newcastle) (Project Newcastle), then use the generic fetcher to download the pre-built artifact into the hermetic build. A CI workflow (e.g., a GitHub Action) triggers the PNC build, extracts the artifact URL and checksum, and commits the resulting `artifacts.lock.yaml`. The Dockerfile.konflux then just unpacks the pre-built artifact — no `mvn` or `gradle` runs inside the container at all. See [trustyai-explainability](https://github.com/red-hat-data-services/trustyai-explainability/tree/rhoai-3.5-ea.1) for a working example of this pattern.

## Building with Prefetched Dependencies

Once you have a correct `hermeto-test.json` (see [Configuring hermeto-test.json](#configuring-hermeto-testjson)), these steps download the dependencies and set up your build to use them offline.

> **Reminder:** Do not commit the `. /cachi2/cachi2.env` sourcing into your Dockerfile.konflux — the pipeline handles this automatically (see the [warning in Quick Start](#quick-start)). The steps below are for **local testing only**.

### 1. Fetch dependencies

This is where hermeto actually downloads all the dependencies defined by your config into a local output directory:

```bash
hermeto fetch-deps \
  --source . \
  --output .hermeto \
  hermeto-test.json
```

You may want to add `.hermeto/` and `.hermeto.env` to your `.gitignore` and `.dockerignore` now — these are local testing artifacts that should not be committed. See [What to Commit](#what-to-commit) for the full checklist.

### 2. Generate the environment file and modify the Dockerfile

```bash
hermeto generate-env .hermeto/ -o .hermeto.env \
  --for-output-dir /cachi2/output
```

This creates a file containing the environment variables that configure package managers (pip, cargo, npm, etc.) to install from the prefetched cache instead of the network. The `--for-output-dir` flag sets the absolute path where the output will be mounted inside the build container -- for Konflux builds this is `/cachi2/output`.

This environment file must be sourced before every `RUN` command in your Dockerfile that installs dependencies. In the Konflux build task, [this is handled automatically](https://github.com/konflux-ci/build-definitions/blob/44ffba6bd5e8a3da0511b13677b3a0982ae6722e/task/buildah-oci-ta/0.8/buildah-oci-ta.yaml#L749-L754) by using sed to inject `. /cachi2/cachi2.env &&` at the start of every `RUN` instruction.

For local testing, generate a modified copy of your Dockerfile with the same sed command rather than editing the original in-place (the Makefile also takes this approach):

```bash
sed -E \
  -e 'H;1h;$!d;x' \
  -e 's@^\s*(run((\s|\\\n)+-\S+)*(\s|\\\n)+)@\1. /cachi2/cachi2.env \&\& \\\n    @igM' \
  Dockerfile.konflux > .hermeto/Dockerfile.konflux
```

The regex matches every `RUN` instruction — including those with flags like `RUN --mount=type=cache ...` — and prepends `. /cachi2/cachi2.env &&` so the environment is sourced before each command. This produces `.hermeto/Dockerfile.konflux` with the env file sourced in every `RUN`, leaving your original Dockerfile untouched. Use this generated Dockerfile for the local hermetic build in step 4.

> **macOS note:** The `M` (multiline) flag in the sed command above is a GNU extension. macOS ships BSD sed, which does not support it. Install GNU sed with `brew install gnu-sed` and use `gsed` instead of `sed`.

### 3. Inject configuration files

```bash
hermeto inject-files ./.hermeto --for-output-dir /cachi2/output
```

Some package managers need config files created or modified to point at the local cache -- for example, cargo requires a `.cargo/config.toml` with the local registry path, and gomod needs `GONOSUMDB`/`GONOSUMCHECK` settings. This step handles that automatically. Not all package managers need it (pip and rpm do not), but it is safe to run regardless. Note that this may overwrite files in your working tree.

### 4. Test locally with a hermetic build

```bash
podman build . \
  --volume "$(realpath ./.hermeto)":/cachi2/output:Z \
  --volume "$(realpath ./.hermeto.env)":/cachi2/cachi2.env:Z \
  --volume "$(realpath ./.hermeto)/deps/rpm/$(uname -m)/repos.d":/etc/yum.repos.d:Z \
  --network none \
  -f .hermeto/Dockerfile.konflux
```

- `--network none` proves that all dependencies are actually prefetched.
- The `.` after `podman build` is the build context directory. Change it if your Dockerfile expects a different context. For example, if your pipeline uses `path-context: python` and `dockerfile: ../Dockerfile.konflux`, run `podman build python/ -f .hermeto/Dockerfile.konflux ...` — the context is the subdirectory, but the Dockerfile remains at the repo root. Getting this wrong causes `COPY` instructions to fail with confusing "file not found" errors.
- The RPM `repos.d` volume mount is only needed if you use the RPM prefetcher. Omit it if you don't prefetch RPMs.
- On Apple Silicon Macs, `uname -m` returns `arm64` but the RPM repo path uses the Linux name `aarch64`. Replace `$(uname -m)` with `aarch64` explicitly.

## Testing on Remote Architectures

Konflux builds run on x86_64, aarch64, ppc64le, and s390x. Your local machine is only one of these, so to validate your hermetic build on other architectures you can run config and prefetch locally, then sync to a remote host for just the podman build. Hermeto downloads dependencies for all architectures declared in your config, so prefetch doesn't need to run on the target host. Ideally, `podman` is the only dependency needed on the remote host. See the [Beaker VM provisioning guide](beaker-vm.md) for how to get a machine on a different architecture.

Before syncing, make sure the following have been generated locally (see [Building with Prefetched Dependencies](#building-with-prefetched-dependencies)):

- `.hermeto/` -- the prefetched output directory (from `fetch-deps`)
- `.hermeto.env` -- the environment file (from `generate-env`)
- `.hermeto/Dockerfile.konflux` -- the modified Dockerfile with env injection (from the `sed` command)
- Any injected config files (from `inject-files`)

Sync the project to the remote host:

```bash
rsync -az --delete \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  --exclude 'node_modules' \
  --exclude 'target' \
  --exclude '.bundle' \
  . user@remote-host:/tmp/myproject
```

Exclude local build artifacts and dependency caches that aren't needed on the remote host -- the hermetic build uses prefetched dependencies from `.hermeto/` instead. Remove any `--exclude` lines that don't apply to your project. Do NOT exclude `.hermeto/` -- it contains the prefetched output the build needs.

Then SSH in and run the `podman build` from [step 4](#4-test-locally-with-a-hermetic-build). The remote host only needs `podman` -- it doesn't need hermeto, uv, or any other tooling.

### Container registry auth on remote hosts

If your Dockerfile pulls from a private registry (e.g., `quay.io/aipcc/base-images/...`), the remote host needs credentials to pull the base image. Don't copy your full `~/.config/containers/auth.json` -- it contains tokens for every registry you've ever logged into.

**Option 1: `podman login` on the remote host**

SSH in and log in directly to the registry that hosts your base image:

```bash
ssh root@remote-host
podman login quay.io
```

Enter your Quay credentials when prompted. This creates an `auth.json` on the remote host scoped to just that registry.

**Option 2: Extract a registry-scoped auth snippet**

If you can't log in interactively on the remote host (e.g., scripted provisioning), extract just the auth entry for the needed registry from your local auth file and send only that:

```bash
# Extract only the quay.io auth entry from your local auth.json
python3 -c "
import json, sys
auth = json.load(open(sys.argv[1]))
scoped = {'auths': {k: v for k, v in auth['auths'].items() if 'quay.io' in k}}
json.dump(scoped, sys.stdout, indent=2)
" ~/.config/containers/auth.json > /tmp/quay-auth.json

# Copy the scoped file to the remote host
scp /tmp/quay-auth.json root@remote-host:~/.config/containers/auth.json
rm /tmp/quay-auth.json
```

This avoids exposing credentials for registries unrelated to the build.

> **Note:** On RHEL 9 / Beaker hosts, rootful podman reads auth from `~/.config/containers/auth.json`. If `podman pull` still shows `unauthorized`, check which path podman is reading with `podman info | grep auth` and place the file accordingly.

For projects where you test on remote hosts frequently, a wrapper script avoids repeating these steps:

```bash
#!/bin/bash
set -euo pipefail

HOST="${1:?Usage: $0 <user@host>}"
REMOTE_DIR="/tmp/myproject"

ssh "$HOST" 'sudo dnf install -y rsync podman'

rsync -az --delete \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  --exclude 'node_modules' \
  --exclude 'target' \
  --exclude '.bundle' \
  . "$HOST:$REMOTE_DIR"

# Drop into a shell on the remote host to run the build
ssh -t "$HOST" "cd $REMOTE_DIR && echo 'Ready on \$(uname -m).' && exec bash -l"
```

If you're using the cookbook Makefile (see [Makefile-Based Workflow](#makefile-based-workflow)), the local prefetch and Dockerfile generation steps can be replaced with `make -f Makefile.hermeto-build prefetch dockerfile` before syncing.

## Makefile-Based Workflow

For iterative development, the cookbook provides `Makefile.hermeto-build` to automate the prefetch→sed→build pipeline. It tracks file timestamps so you can re-run individual stages without starting from scratch.

Write `hermeto-test.json` by hand (or with the skill) following the [config reference](#configuring-hermeto-testjson) above -- the config varies too much per project to automate generically.

### Setup

Copy the Makefile into your project:

```bash
cp /path/to/konflux-cookbook/scripts/Makefile.hermeto-build .
```

Override variables on the command line:

```bash
make -f Makefile.hermeto-build DOCKERFILE=Dockerfile.konflux build
```

### Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HERMETO_CONFIG` | `hermeto-test.json` | Path to hermeto JSON config |
| `HERMETO_OUTPUT` | `.hermeto` | Output directory for prefetched deps |
| `DOCKERFILE` | `Dockerfile.konflux` | Source Dockerfile to transform |
| `BUILD_CONTEXT` | `.` | Docker build context directory |

### Available Targets

```bash
make -f Makefile.hermeto-build prefetch    # prefetch everything into .hermeto/
make -f Makefile.hermeto-build dockerfile  # generate hermetic Dockerfile
make -f Makefile.hermeto-build build       # full offline podman build (runs prefetch + dockerfile first)
make -f Makefile.hermeto-build clean       # remove .hermeto/ and .hermeto.env
```

## Dockerfile Reference

For reference, here is what the Dockerfile looks like *after* the pipeline's automatic sed injection. This is not what you commit -- it shows the transformed version that runs at build time (and what the local testing sed command in [step 2](#2-generate-the-environment-file-and-modify-the-dockerfile) produces):

```dockerfile
FROM registry.access.redhat.com/ubi9/python-312-minimal AS base

USER 0

RUN . /cachi2/cachi2.env && \
    microdnf install -y gcc make python3.12-devel cargo && \
    microdnf clean all

WORKDIR /app
COPY ./requirements.txt ./

RUN . /cachi2/cachi2.env && \
    python -m pip install -r requirements.txt

COPY . .
USER 1001
ENTRYPOINT ["python", "-m", "myapp"]
```

Each `RUN` is a separate shell, so `. /cachi2/cachi2.env` must appear in every one that calls pip, cargo, npm, etc. For **Cargo + pip** projects (e.g., Python packages with Rust extensions), the env file configures both package managers at once.

## Python Requirements, AIPCC, and Source Builds

For generating pinned requirements files, using AIPCC prebuilt wheels, and building from source on architectures that lack wheels, see the **[Python and AIPCC Guide](hermeto-python.md)**.

## RPM Dependencies

System packages needed at build time (compilers, -devel libraries) are declared in `rpms.in.yaml` so Konflux can prefetch them too. This avoids relying on network access to install RPMs during the build.

### rpms.in.yaml

```yaml
arches:
  - x86_64
  - aarch64
  - ppc64le
  - s390x
contentOrigin:
  repofiles:
    - "./ubi.repo"
packages:
  - gcc
  - make
  - python3.12-devel
  - cargo
  - g++
  - libffi-devel
  - openssl-devel
  - perl
context:
  containerfile:
    file: "./Dockerfile.konflux"
    stageName: base
```

The `context.containerfile` field tells the lockfile generator which Dockerfile stage needs these packages, so it can resolve the correct base image repositories. You can select the target stage by `stageName`, `imagePattern`, or `stageNum` — or omit all three to default to the last stage. This works for both single-stage and multi-stage Dockerfiles, and covers the common pattern where RPMs are installed in the final (runtime) stage. See the [rpm-lockfile-prototype docs](https://github.com/konflux-ci/rpm-lockfile-prototype) for the full syntax.

The `containerfile` value can be either an object (with `file`, `stageName`, etc.) or a bare string path. The bare string form is equivalent to an object with just `file` set:

```yaml
# Bare string (simplest — defaults to last stage)
context:
  containerfile: Dockerfile.konflux

# Bare string with a subdirectory path
context:
  containerfile: Dockerfiles/Dockerfile.konflux

# Object form: match by stage name
context:
  containerfile:
    file: "./Dockerfile.konflux"
    stageName: base

# Object form: match by base image pattern
context:
  containerfile:
    file: Dockerfiles/controller.Dockerfile.konflux
    imagePattern: ubi9/ubi-minimal
```

**Multi-component repos:** If multiple components in the same repo install system packages and share the same base image, a single `rpms.in.yaml` at the repo root can serve all of them. List the union of all packages needed across components — the prefetched RPMs are a cache, and each component's `dnf install` pulls only what it needs. The `containerfile` can reference any one component's Dockerfile since the available repos are determined by the base image, which is the same for all components.

If components use different base images (e.g., one uses `ubi9/go-toolset` and another uses `ubi9/python-312`), you need separate `rpms.in.yaml` and `rpms.lock.yaml` files because the available repos differ by base image. Place each pair in its own subdirectory with its own `containerfile` reference, and point each component's pipeline at the right one with `{"type": "rpm", "path": "<subdir>"}` — the `path` is a directory, and hermeto always looks for `rpms.lock.yaml` in it.

**Multi-stage RPM resolution:** The same applies within a single component when different Dockerfile stages install packages from different base images (e.g., an AIPCC CUDA builder stage and a UBI runtime stage). Create separate `rpms.in.yaml`/`rpms.lock.yaml` pairs in different subdirectories, each with its own `containerfile` targeting the appropriate stage via `stageName`. List both in the component's `prefetch-input`:

```json
[
  {"type": "rpm", "path": "tools"},
  {"type": "rpm", "path": "tools/builder"}
]
```

Where `tools/rpms.in.yaml` targets the runtime stage (using `ubi.repo`) and `tools/builder/rpms.in.yaml` targets the builder stage (using a different repo source like `redhat.repo` for entitlement-based RHEL repos). See [rhaii-cluster-validation](https://github.com/red-hat-data-services/rhaii-cluster-validation/tree/rhoai-3.5-ea.1) for a working example.

The `contentOrigin` section can also be inlined instead of referencing a repo file. Include CodeReady Builder repos if you need packages like `ninja-build` that aren't in baseos or appstream:

```yaml
contentOrigin:
  repos:
  - repoid: ubi-9-for-$basearch-baseos-rpms
    baseurl: https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/$basearch/baseos/os
  - repoid: ubi-9-for-$basearch-baseos-source-rpms
    baseurl: https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/$basearch/baseos/source/SRPMS
  - repoid: ubi-9-for-$basearch-appstream-rpms
    baseurl: https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/$basearch/appstream/os
  - repoid: ubi-9-for-$basearch-appstream-source-rpms
    baseurl: https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/$basearch/appstream/source/SRPMS
  - repoid: codeready-builder-for-ubi-9-$basearch-rpms
    baseurl: https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/$basearch/codeready-builder/os
  - repoid: codeready-builder-for-ubi-9-$basearch-source-rpms
    baseurl: https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/$basearch/codeready-builder/source/SRPMS
```

**EPEL packages:**

If you need packages from EPEL, add the EPEL repo inline in `rpms.in.yaml` with `gpgcheck: 0`:

```yaml
contentOrigin:
  repos:
  - repoid: ubi-9-for-$basearch-baseos-rpms
    baseurl: https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/$basearch/baseos/os
  - repoid: ubi-9-for-$basearch-appstream-rpms
    baseurl: https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/$basearch/appstream/os
  - repoid: epel-9
    metalink: https://mirrors.fedoraproject.org/metalink?repo=epel-9&arch=$basearch
    gpgcheck: 0
```

> **Red Hat note:** EPEL packages cannot be used in productized builds without a ProdSec exception. Check with your product security team before adding EPEL dependencies to a shipped image.

### Generating rpms.lock.yaml

Use [rpm-lockfile-prototype](https://github.com/konflux-ci/rpm-lockfile-prototype) to resolve and lock RPM versions:

```bash
curl https://raw.githubusercontent.com/konflux-ci/rpm-lockfile-prototype/refs/heads/main/Containerfile \
   | podman build -t localhost/rpm-lockfile-prototype -

podman run --rm -v "${PWD}:/work:Z" localhost/rpm-lockfile-prototype:latest --outfile=rpms.lock.yaml rpms.in.yaml
```

This produces `rpms.lock.yaml` with exact URLs and checksums for every RPM (including transitive dependencies) across all declared architectures. The lockfile is typically large -- thousands of lines is normal. Commit both `rpms.in.yaml` and `rpms.lock.yaml`.

### Using RPM prefetch in your Dockerfile

No changes needed in the Dockerfile itself. The Konflux build pipeline handles RPM prefetch automatically when it finds `rpms.lock.yaml`. The RPMs are made available through the same `/cachi2/` mount, and `microdnf install` works because the env file configures the local RPM repo.

## What to Commit

Once your hermetic build is working:

**Commit these files:**
- Compiled/pinned requirements files (`requirements.txt`, `requirements-build.txt`, etc.)
- `rpms.in.yaml` and `rpms.lock.yaml` (if using RPM prefetch)

**Do not commit:**
- `hermeto-test.json` -- for local testing only. The config is inlined in the Tekton PipelineRun prefetch task parameter.
- `.hermeto/` -- the prefetched output directory
- `.hermeto.env` -- the generated environment file

Consider adding these to `.gitignore` and `.dockerignore` to avoid accidentally committing or including the prefetched output (which can be hundreds of MB) in the build context.

**Consider automating lockfile regeneration:**
- Lockfiles like `requirements.txt`, `requirements-build.txt`, and `rpms.lock.yaml` need to be regenerated when dependencies change. Consider adding a Makefile target, script, or CI job to automate this so the committed lockfiles stay in sync with your project's dependency declarations.

**Update in Tekton:**
- Copy the contents of `hermeto-test.json` into the prefetch task parameter in your `.tekton/` PipelineRun

## Common Gotchas

For Python and AIPCC-specific gotchas (uv/pip compatibility, build backend issues, hash problems, pre-release version conflicts), see the [Python guide's Common Gotchas](hermeto-python.md#common-gotchas).

### Cargo: git-sourced dependencies not redirected

Hermeto generates `.cargo/config.toml` to redirect crates.io sources to the local vendor directory, but it does **not** handle git-sourced dependencies. If a crate pulls from a git repo (common with `pyca/cryptography`), Cargo will try to fetch from the network and fail in a hermetic build.

**Workaround:** Overwrite the generated config to add the git source redirect manually:

```toml
[source.crates-io]
replace-with = "local"

[source."git+https://github.com/pyca/cryptography.git?tag=45.0.4"]
git = "https://github.com/pyca/cryptography.git"
tag = "45.0.4"
replace-with = "local"

[source.local]
directory = "/cachi2/output/deps/cargo"
```

Write this to `/cachi2/output/.cargo/config.toml` in a build script that runs before `pip install` or `cargo build`.

### Rust version constraints (MATURIN_PEP517_ARGS)

Some Python packages with Rust extensions (e.g., `hf-xet`) require a newer Rust toolchain than what the UBI9 base image ships. If the build fails with a Rust version error:

**Workaround:** Pass `--ignore-rust-version` to maturin via the environment variable:

```bash
MATURIN_PEP517_ARGS="--ignore-rust-version" pip install <package>
```

This skips the minimum Rust version check. Remove this workaround once the base image ships a sufficiently new Rust.

### Missing system libraries

Python packages with C or Rust extensions often need development headers at build time. Common ones that are **not** in the minimal UBI9 image:

| Package | Needed for |
|---------|-----------|
| `libffi-devel` | cffi, cryptography |
| `openssl-devel` | cryptography, rfc3161-client (on some arches) |
| `perl` | openssl-sys build (when `OPENSSL_NO_VENDOR` is not set) |
| `python3.12-devel` | Any C extension compiled against Python |
| `gcc`, `g++`, `make` | General native compilation |
| `cargo` | Rust extensions via maturin |

If you prefetch RPMs, these packages need to appear in both `rpms.in.yaml` (so they're prefetched) and the `dnf install` line in your Dockerfile (so they're installed). Missing one side or the other causes either a prefetch gap or a network failure.

### Using permissive mode for mismatched lockfiles

Some Rust extensions ship with out-of-sync `Cargo.lock` / `Cargo.toml`. If `hermeto fetch-deps` fails due to lockfile mismatches or other non-fatal inconsistencies:

```bash
hermeto --mode permissive fetch-deps hermeto-test.json
```

This regenerates lockfiles instead of erroring out. Note that this reduces reproducibility -- the SBOM may not perfectly reflect what was built.

In a Konflux pipeline, set the `prefetch-mode` parameter to add `--mode permissive` to the hermeto invocation in the build:

```yaml
- name: prefetch-mode
  value: "permissive"
```

### macOS: sed command for Dockerfile injection

The sed command in [step 2](#2-generate-the-environment-file-and-modify-the-dockerfile) uses the `M` (multiline) flag, which is a GNU extension. macOS ships BSD sed, which does not support it.

**Fix:** Install GNU sed with `brew install gnu-sed` and use `gsed` instead of `sed` in the command.

### Eliminating build stages instead of hermeticizing them

Before adding prefetch entries for every network access point in your Dockerfile, consider whether each build stage is essential to the final image. Stages that produce optional artifacts — test fixtures, sample compilations, CLI tools only used in CI — can sometimes be removed from Dockerfile.konflux entirely rather than made hermetic. This is simpler than adding pip, generic, or npm prefetch entries for stages whose output is not shipped in the production image. For example, the [data-science-pipelines](https://github.com/red-hat-data-services/data-science-pipelines/tree/rhoai-3.5-ea.1) api-server removed an entire Python compiler stage (pip installs, Argo CLI download, sample compilation) from Dockerfile.konflux because those artifacts are produced by a separate CI pipeline.

### Organizing workarounds

If you have multiple hermetic build fixes, collect them in a shell script (e.g., `hermetic_fixes.sh`) rather than bloating the Dockerfile. This makes it clear which steps are temporary workarounds vs. permanent build logic, and makes it easier to remove them once the root cause is fixed upstream:

```dockerfile
COPY ./hermetic_fixes.sh ./
RUN ./hermetic_fixes.sh
```

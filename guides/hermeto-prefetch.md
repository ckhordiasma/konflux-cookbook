# Using Hermeto to Prefetch Dependencies for Hermetic Konflux Builds

## What is Hermeto

Hermeto is a CLI tool that pre-fetches project dependencies so that container builds can run without network access (hermetic builds). It downloads all declared dependencies from lockfiles into a local output directory, generates an SBOM, and produces environment files that configure package managers to use the local cache instead of reaching out to the internet. Hermeto is the renamed successor of Cachi2 -- the output directory and environment file in this guide (and in konflux) still use the `/cachi2/` paths for backward compatibility.

## Installing Hermeto

The easiest way to run hermeto locally is through its container image. Set up a shell alias so you can use `hermeto` as if it were installed natively:

```bash
alias hermeto='podman run --rm -ti -v "$PWD:$PWD:z" -w "$PWD" \
  ghcr.io/hermetoproject/hermeto:latest'
```

The `-v "$PWD:$PWD:z"` flag bind-mounts your project directory into the container so hermeto can read your lockfiles and write output, and `-w "$PWD"` sets the working directory to match. All `hermeto` commands in this guide assume this alias is in place.

## Configuring `hermeto.json`

The first step is to create a correct hermeto config. This is a JSON array of package manager objects, each with a `type` field and manager-specific options. In this guide, we save it to a file called `hermeto.json` for local testing, but in your Konflux build pipeline the JSON is typically inlined as a parameter to the prefetch task. For single-manager configs, the pipeline also accepts a bare JSON object (e.g., `{"type": "gomod", "path": "."}`) without the array wrapper.

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
  hermeto.json
```

Once `fetch-deps` is used to download the dependencies, some additional configuration is needed to actually get a local offline build working. See [Building with Prefetched Dependencies](#building-with-prefetched-dependencies) for how to properly use the prefetched output in a hermetic build.

### pip (Python)

[Hermeto pip docs](https://hermetoproject.github.io/hermeto/latest/pip/)

Hermeto requires a fully resolved `requirements.txt` with all transitive dependencies pinned to exact versions (e.g., `package==1.2.3`). Hashes are optional but recommended for PyPI packages, and mandatory for HTTPS URL dependencies. If any of your dependencies are sdists (no pre-built wheel available), you also need a `requirements-build.txt` listing their PEP 517 build backends. See [Python Requirements](#python-requirements) for how to generate these files.

Some packages lack wheels or sdists on PyPI for certain architectures -- this is common on ppc64le and s390x. See [Using AIPCC Wheels](#using-aipcc-wheels) to review how to leverage pre-built wheels built by the AIPCC team, or [Building from Source for Missing Architectures](#building-from-source-for-missing-architectures) for how to build packages like torch from source tarballs.

**Config fields:**

| Field | Default | Description |
|-------|---------|-------------|
| `path` | `"."` | Directory containing requirements files, relative to `--source` |
| `requirements_files` | `["requirements.txt"]` | List of pinned requirements files (see [Python Requirements](#python-requirements)) |
| `requirements_build_files` | `["requirements-build.txt"]` or `[]` | Build backend dependencies for sdists (see [Python Requirements](#python-requirements)). Defaults to `["requirements-build.txt"]` if the file exists, `[]` otherwise |
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

1. **Use a custom index** like AIPCC that publishes prebuilt wheels for all architectures (see [Using AIPCC wheels](#using-aipcc-wheels)). This is the preferred approach -- hermeto handles arch selection at download time, so one requirements file works for all architectures.
2. **Build from source** by prefetching the source tarball through `requirements_build_files` alongside the build backends needed to compile it. Pip will use PyPI wheels where available and fall back to the source tarball on architectures that lack wheels. See [Building from source for missing architectures](#building-from-source-for-missing-architectures) for a worked example.

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

**Multi-module repos with Go workspaces:** If your repo contains multiple Go modules (separate `go.mod` files), check whether they're joined by a [`go.work`](https://go.dev/doc/tutorial/workspaces) file. When a `go.work` exists at the workspace root, Go tooling unifies the dependency graph across all workspace modules. A single `{"type": "gomod", "path": "."}` entry pointing at the workspace root is sufficient — hermeto's Go tooling respects the workspace and prefetches dependencies for all included modules.

**Multi-module repos with `replace` directives:** If the root `go.mod` uses `replace` directives to point at local submodules (e.g., `replace github.com/org/repo/api => ./api`), a single gomod entry at the root is also sufficient — Go resolves the local modules through the replacement path, so hermeto prefetches all external dependencies in one pass. This is common in operator repos where an `api/` submodule is consumed by the main module.

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

Dependencies are declared in an `artifacts.lock.yaml` lockfile rather than in `hermeto.json` options:

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

Each artifact requires a `checksum` in `algorithm:hash` format. Downloaded files are stored in `deps/generic/` within the output directory.

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

Each network access point maps to a hermeto package manager config (see [Configuring hermeto.json](#configuring-hermetojson)) or needs a manual workaround.

Only network access in the Dockerfile matters. A repo may contain lockfiles (e.g., `package-lock.json` for a documentation site, or `requirements.txt` for a test suite) that are never referenced by the container build -- these do not need hermeto entries. The Dockerfile is your guide, not the repo's file listing.

Multiple commands using the same package manager still map to a single hermeto entry. For example, a Dockerfile might run `npm ci` for a full install during the build stage and then `npm install --omit=dev` to prune to production dependencies. Both draw from the same prefetched cache -- hermeto prefetches everything in the lockfile, and each `npm` command finds what it needs regardless of flags like `--omit=dev` or `--ignore-scripts`.

If the project has multiple Dockerfiles, identify which one is the target for hermetic builds. Also check whether the Dockerfile requires additional build inputs (argfiles, build-args, `.env` files) that affect what gets installed.[^no-deps]

[^no-deps]: If your analysis finds zero network access points, you don't need hermeto at all. Set `hermetic: true` in your pipeline without `prefetch-input` — the build succeeds with nothing to prefetch. This is common for data-only containers that just COPY static files into the image.

### Iterate one package manager at a time

Getting a hermetic build working is an iterative process. The core loop for each package manager is:

1. Add the manager to `hermeto.json` -- start with the simplest valid config (just `type` and `path`), then add options as needed (e.g., `binary` for wheels, `requirements_build_files` for sdists)
2. Run `hermeto fetch-deps` -- expect this to fail at first while you refine the config
3. Fix issues (missing lockfiles, wrong options, version mismatches) and re-run until fetch-deps succeeds
4. Run a build to verify the prefetched deps actually work

You can work through package managers one at a time rather than configuring everything upfront. This works because some managers (like pip) use the prefetched cache automatically once the hermeto env vars are injected into the Dockerfile -- so you can run `podman build --network none` to verify that *the current manager* is fully hermetic while other managers (like RPMs) still use the network. Once one manager is confirmed hermetic, move on to the next.

Alternatively, you can configure all managers in `hermeto.json` first, get `fetch-deps` passing for everything, and then do a single full hermetic build at the end. Choose whichever approach suits the complexity of your project.

## Building with Prefetched Dependencies

Once you have a correct `hermeto.json` (see [Configuring hermeto.json](#configuring-hermetojson)), these steps download the dependencies and set up your build to use them offline.

> **Do not commit `. /cachi2/cachi2.env` sourcing into your Dockerfile.konflux.** The Konflux build pipeline [automatically injects](https://github.com/konflux-ci/build-definitions/blob/44ffba6bd5e8a3da0511b13677b3a0982ae6722e/task/buildah-oci-ta/0.8/buildah-oci-ta.yaml#L749-L754) `. /cachi2/cachi2.env &&` before every `RUN` instruction at build time using a sed transform. The generate-env and sed steps below replicate this behavior for **local testing** -- use them to produce a temporary modified Dockerfile for `podman build`, but do not check those changes into your committed Dockerfile.konflux.

### 1. Fetch dependencies

This is where hermeto actually downloads all the dependencies defined by your config into a local output directory:

```bash
hermeto fetch-deps \
  --source . \
  --output .hermeto \
  hermeto.json
```

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

This produces `.hermeto/Dockerfile.konflux` with the env file sourced in every `RUN` command, leaving your original Dockerfile untouched. Use this generated Dockerfile for the local hermetic build in step 4.

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

If you're using the cookbook Makefiles (see [Makefile-Based Workflow](#makefile-based-workflow)), the local prefetch and Dockerfile generation steps can be replaced with `make -f Makefile.hermeto-build prefetch dockerfile` before syncing.

## Makefile-Based Workflow

For iterative development, Makefiles let you run individual stages without re-running everything from scratch. The cookbook includes two parameterized Makefiles that split the workflow into config and build:

- **`Makefile.hermeto-config`** -- Resolves lockfiles and generates `hermeto.json`
- **`Makefile.hermeto-build`** -- Prefetches dependencies and runs the hermetic build

### Setup

Copy both Makefiles into your project:

```bash
cp /path/to/konflux-cookbook/scripts/Makefile.hermeto-config .
cp /path/to/konflux-cookbook/scripts/Makefile.hermeto-build .
```

Override variables on the command line:

```bash
make -f Makefile.hermeto-config PYTHON_VERSION=3.12 PIP_INPUT=pyproject.toml
make -f Makefile.hermeto-build DOCKERFILE=Dockerfile.konflux build
```

### Configuration Variables

**Makefile.hermeto-config:**

| Variable | Default | Description |
|----------|---------|-------------|
| `PYTHON_VERSION` | `3.9` | Target Python version (must match base image) |
| `PIP_INPUT` | `requirements.in` | Input file to compile (`requirements.in`, `pyproject.toml`, etc.) |
| `PIP_OUTPUT` | `requirements.txt` | Output pinned requirements file |
| `REQUIREMENTS_BUILD` | `requirements-build.txt` | Build-dep output file (empty to skip) |
| `INDEX_URL` | *(empty)* | Custom package index URL (e.g., AIPCC) |
| `EXTRA_UV_ARGS` | *(empty)* | Extra args for uv pip compile (e.g., `--extra server`) |
| `BINARY_ARCH` | `x86_64,aarch64,ppc64le,s390x` | Binary wheel architectures |
| `REQUIREMENTS_FILES` | `$(PIP_OUTPUT)` | Requirements files to list in hermeto.json |
| `REQUIREMENTS_BUILD_FILES` | `$(REQUIREMENTS_BUILD)` | Build-dep files to list in hermeto.json |
| `HERMETO_CONFIG` | `hermeto.json` | Path to generated config |

**Makefile.hermeto-build:**

| Variable | Default | Description |
|----------|---------|-------------|
| `HERMETO_CONFIG` | `hermeto.json` | Path to hermeto JSON config |
| `HERMETO_OUTPUT` | `.hermeto` | Output directory for prefetched deps |
| `DOCKERFILE` | `Dockerfile.konflux` | Source Dockerfile to transform |
| `BUILD_CONTEXT` | `.` | Docker build context directory |

### Available Targets

Run any stage independently -- Make tracks file timestamps and skips work that's already done:

```bash
# Config stage (Makefile.hermeto-config)
make -f Makefile.hermeto-config pip-compile     # resolve .in -> .txt
make -f Makefile.hermeto-config build-deps      # find build backends (pybuild-deps)
make -f Makefile.hermeto-config rpm-lock        # generate rpms.lock.yaml
make -f Makefile.hermeto-config hermeto-config  # generate hermeto.json
make -f Makefile.hermeto-config clean           # remove generated lockfiles + config

# Build stage (Makefile.hermeto-build)
make -f Makefile.hermeto-build prefetch          # prefetch everything into .hermeto/
make -f Makefile.hermeto-build dockerfile       # generate hermetic Dockerfile
make -f Makefile.hermeto-build build            # full offline podman build
make -f Makefile.hermeto-build clean            # remove .hermeto/ and .hermeto.env
```

Running `make -f Makefile.hermeto-config` with no target runs all config stages end-to-end (pip-compile, build-deps, hermeto-config). Running `make -f Makefile.hermeto-build build` runs the prefetch, Dockerfile transform, and podman build.

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

## Python Requirements

Hermeto expects fully pinned `requirements.txt` files listing every transitive dependency. If your project only has a `requirements.in` (or `pyproject.toml`), you need to compile it into a pinned lockfile first.

### Compiling requirements.txt

Use `uv pip compile` to resolve and pin all transitive dependencies. Use `--python-version` to match the Python version in your base image -- this ensures the resolver picks the right dependency versions:

```bash
uv pip compile requirements.in \
  --python-platform linux \
  --python-version 3.9 \
  --index-strategy first-index \
  -o requirements.txt
```

If you use a custom package index (like AIPCC), add `--emit-index-annotation` so the compiled file records which index each package came from. You can also use `--index-url` in the requirements file or pass `--index` to uv to specify the index.

### Alternative: `uv export` from `uv.lock`

If your project uses `uv` as its package manager, you can generate `requirements.txt` from a `uv.lock` file instead of using `uv pip compile`:

```bash
uv lock
uv export --format requirements-txt --output-file requirements.txt
```

This keeps index and resolution configuration in `pyproject.toml` rather than on the command line. Key `[tool.uv]` features that help produce the right requirements file for hermeto:

- **`[[tool.uv.index]]` + `[tool.uv.sources]`** — configure per-package index routing (e.g., most packages from AIPCC, specific packages from a test index or PyPI)
- **`environments`** — restrict resolution to target platforms only (e.g., Linux x86_64 and aarch64), preventing unnecessary platform-specific dependencies from appearing in the output
- **`override-dependencies`** — exclude transitive dependencies not available in your index (e.g., `"modelscope; python_version < '0'"` uses an always-false marker to drop the package)

Commit `uv.lock` alongside the generated `requirements.txt`. When dependencies change, run `uv lock` then `uv export` to regenerate.

### Projects with local path dependencies

If your project contains multiple Python packages that depend on each other via `[tool.uv.sources]` path references, hermeto cannot resolve those local paths — it needs flat requirements files listing only external packages with pinned versions. The local packages themselves are installed from source in the Dockerfile, not prefetched.

Suppose your repo has this structure:

```
python/
  kserve/pyproject.toml          # standalone
  storage/pyproject.toml         # depends on kserve
  autogluonserver/pyproject.toml # depends on kserve and storage
```

There are several ways to structure the compile, prefetch, and install:

**Combined file** — compile from the top-level package, which pulls in all transitive dependencies through its dependency chain:

```bash
uv pip compile python/autogluonserver/pyproject.toml \
  --python-platform linux \
  --python-version 3.12 \
  -o python/autogluonserver/requirements.txt
```

```json
[
  {
    "type": "pip",
    "path": "python/autogluonserver",
    "requirements_files": ["requirements.txt"]
  }
]
```

```dockerfile
RUN pip install -r autogluonserver/requirements.txt
RUN cd kserve && pip install .
RUN cd storage && pip install .
RUN cd autogluonserver && pip install .
```

**Separate files, one pip entry** — compile each package independently and list all files in a single entry. The `path` must be a common ancestor of all the requirements files:

```bash
uv pip compile python/kserve/pyproject.toml -o python/kserve/requirements.txt ...
uv pip compile python/storage/pyproject.toml -o python/storage/requirements.txt ...
uv pip compile python/autogluonserver/pyproject.toml -o python/autogluonserver/requirements.txt ...
```

```json
[
  {
    "type": "pip",
    "path": "python",
    "requirements_files": [
      "kserve/requirements.txt",
      "storage/requirements.txt",
      "autogluonserver/requirements.txt"
    ]
  }
]
```

```dockerfile
RUN pip install \
    -r kserve/requirements.txt \
    -r storage/requirements.txt \
    -r autogluonserver/requirements.txt
RUN cd kserve && pip install .
RUN cd storage && pip install .
RUN cd autogluonserver && pip install .
```

**Separate pip entries** — one entry per package directory:

```bash
uv pip compile python/kserve/pyproject.toml -o python/kserve/requirements.txt ...
uv pip compile python/storage/pyproject.toml -o python/storage/requirements.txt ...
uv pip compile python/autogluonserver/pyproject.toml -o python/autogluonserver/requirements.txt ...
```

```json
[
  {"type": "pip", "path": "python/kserve", "requirements_files": ["requirements.txt"]},
  {"type": "pip", "path": "python/storage", "requirements_files": ["requirements.txt"]},
  {"type": "pip", "path": "python/autogluonserver", "requirements_files": ["requirements.txt"]}
]
```

```dockerfile
RUN pip install \
    -r kserve/requirements.txt \
    -r storage/requirements.txt \
    -r autogluonserver/requirements.txt
RUN cd kserve && pip install .
RUN cd storage && pip install .
RUN cd autogluonserver && pip install .
```

The combined approach is simplest — a single `uv pip compile` resolves everything together, avoiding version conflicts between files. With separate files, independently compiled requirements may pin different versions of the same transitive dependency, which can cause install conflicts. If using separate files, consider using `--constraint` to keep versions aligned.

With separate files, be aware that `--index-url` in a requirements file applies only to that file's packages. If one file specifies `--index-url` and another doesn't, the second file's packages are fetched from PyPI.

### Generating requirements-build.txt

Source distributions (sdists) need build backends (hatchling, maturin, pdm-backend, etc.) to compile. Use [pybuild-deps](https://pypi.org/project/pybuild-deps/) to discover these automatically:

```bash
uv run --python 3.9 --with pybuild-deps pybuild-deps compile \
  requirements.txt -o requirements-build.txt
```

Match the `--python` version to your target image. This file is needed if any of your dependencies are installed from source distributions (sdists). If a package has no wheel for your target architecture, you'll need this file along with the native toolchain RPMs to build from source -- or use a custom index like AIPCC that has prebuilt wheels (see [Using AIPCC wheels](#using-aipcc-wheels)).

**Project build backends:** If your Dockerfile runs `pip install .` (or `pip install --no-deps .`) to install the project itself, the project's `[build-system].requires` (e.g., `poetry-core`, `hatchling`, `setuptools`) must also be in `requirements-build.txt`. `uv pip compile` resolves runtime dependencies only — it cannot include build system requirements. Check your `pyproject.toml` for the `[build-system]` section and add its `requires` entries to `requirements-build.txt` manually, pinned to exact versions. If using an AIPCC index, include the `--index-url` directive in `requirements-build.txt` as well so hermeto fetches the build backend from the correct index.

Example `requirements-build.txt` for a project that uses poetry-core:
```
--index-url https://console.redhat.com/api/pypi/public-rhai/rhoai/3.4/cpu-ubi9/simple/
poetry-core==1.9.1
```

Then reference it in your hermeto config:
```json
{
  "type": "pip",
  "path": ".",
  "requirements_files": ["requirements.txt"],
  "requirements_build_files": ["requirements-build.txt"]
}
```

### Using AIPCC wheels

[AIPCC](https://packages.redhat.com/domains/public-rhai/distributions) (AI Platform Core Components) publishes prebuilt Python wheels for all target architectures (x86_64, aarch64, ppc64le, s390x) and accelerator variants (CPU, CUDA, ROCm). Using AIPCC wheels eliminates the need to build packages from source on architectures that lack public PyPI wheels. Several RHOAI components already use AIPCC, including notebooks, mlflow, and mlserver.

**Important:** AIPCC wheels are built with external dependencies on system libraries installed in the corresponding AIPCC base images. Unlike upstream `manylinux` wheels which bundle their dependencies, AIPCC wheels will not work without the matching base image. Do not mix AIPCC wheels with wheels from pypi.org -- ABI incompatibilities between bundled and external dependencies can cause crashes, incorrect output, or libraries that fail to load. Each AIPCC index must be used with its corresponding base image. Packages that link against accelerator-specific libraries (CUDA, ROCm) strictly require the matching AIPCC base image. CPU-only packages that link only against standard system libraries (e.g., OpenSSL, libffi) may work on stock UBI9 images, as mlflow demonstrates — but this is not tested or supported by AIPCC. Pure-Python packages from PyPI are lower risk to mix in since they have no compiled components, but this is unsupported by AIPCC -- if a package you need is missing, [request it](#requesting-packages) instead.

> **Note:** Some components (e.g., mlflow, pipelines-components) prefetch a small number of packages from public PyPI alongside AIPCC. This can work when the PyPI packages are pure-Python or link only against system libraries already present in UBI (e.g., `psycopg2` linking against `libpq`). The key safety practices are:
>
> 1. **Split requirements by index** — maintain separate files for AIPCC packages and PyPI packages (e.g., `requirements-aipcc.txt` and `requirements-pypi.txt`)
> 2. **Use separate pip entries** in the hermeto config — AIPCC entries need `binary: {"arch": ":all:"}`, PyPI entries may not
> 3. **Use `--no-deps` on every `pip install`** in the Dockerfile — this prevents pip from resolving dependencies at install time, so there is no risk of pulling the wrong version from the wrong index
>
> The proper fix is still to get missing packages added to AIPCC so everything comes from a single, supported index.

This applies to any dependency source, not just PyPI. If your project installs packages from git URLs (e.g., `git+https://github.com/org/repo@tag`), those packages must also be published to the AIPCC index. Git-sourced dependencies are incompatible with pip's hash-checking mode, so mixing them with hashed AIPCC packages in the same requirements file does not work. The fix is to get the midstream package onboarded to AIPCC — for example, the llama-stack-provider team had garak published as `garak==0.14.1+rhaiv.8` on the AIPCC index rather than installing it from a git URL.

AIPCC provides separate indexes per RHOAI release and accelerator variant. Browse available indexes at [packages.redhat.com](https://packages.redhat.com/domains/public-rhai/distributions). For RHOAI 3.4:

| Variant | Index URL | Base Image |
|---------|-----------|------------|
| CPU | `.../rhoai/3.4/cpu-ubi9/simple/` | `quay.io/aipcc/base-images/cpu:3.4.0-...` |
| CUDA 12.9 | `.../rhoai/3.4/cuda12.9-ubi9/simple/` | `quay.io/aipcc/base-images/cuda-12.9-el9.6:3.4.0-...` |
| CUDA 13.0 | `.../rhoai/3.4/cuda13.0-ubi9/simple/` | `quay.io/aipcc/base-images/cuda-13.0-el9.6:3.4.0-...` |
| ROCm 6.4 | `.../rhoai/3.4/rocm6.4-ubi9/simple/` | `quay.io/aipcc/base-images/rocm-6.4-el9.6:3.4.0-...` |

The full index URL prefix is `https://console.redhat.com/api/pypi/public-rhai/`. The base images are pre-configured so that `pip` and `uv` pull from the matching index automatically.

#### Requesting packages

If a package you need is missing from the AIPCC index, submit a request through the [AIPCC package request form](https://dashboard.aipcc.redhat.com/package-request) (requires Red Hat VPN). See the [package onboarding docs](https://package-onboarding-0af11e.gitlab.io/) for the full process.

You need to request your project's **dependencies**, not the project itself. If your Dockerfile does `pip install .` to build the project from source, the project's code is installed locally — only its dependencies need to be on the AIPCC index. If your project has an upstream PyPI equivalent (e.g., `mlflow`), you can submit the upstream package name to get its full dependency tree onboarded, even if you don't use the AIPCC-built wheel yourself. If your midstream fork has different dependencies than upstream, request the missing packages individually.

Key points:
- **One submission per PyPI package** — sub-packages with separate PyPI entries need separate requests
- **Transitive dependencies are handled automatically** — only request top-level packages
- **The form handles updates and rebuilds too** — use it for new versions, not just new packages
- **Include a target date and release commitment** if urgent — simple packages can be same-day, complex native builds take longer

Ask in [#forum-aipcc](https://redhat-internal.slack.com/archives/C07JX0EMKCZ) for general questions or [#forum-aipcc-wheels](https://redhat-internal.slack.com/archives/C079FE5H94J) for wheel-specific issues.

**Getting started with AIPCC:**

Start by getting your build working non-hermetically using the AIPCC base image and its pre-configured index. Once your `pip install` succeeds, freeze your dependencies with `uv pip compile` to produce a pinned requirements file that hermeto can prefetch from the AIPCC index.

The `red-hat-data-services/notebooks` repo has already onboarded to AIPCC and shows working combinations of base images and index URLs across RHOAI releases and accelerator variants.

Point `uv pip compile` at the AIPCC index with `--index` and `--index-strategy first-index`. `--emit-index-annotation` is optional but useful -- it annotates each package with the index it was resolved from, making it easy to trace sourcing:

```bash
uv pip compile requirements.in \
  --python-platform linux \
  --python-version 3.12 \
  --index https://console.redhat.com/api/pypi/public-rhai/rhoai/3.4/cpu-ubi9/simple/ \
  --index-strategy first-index \
  --emit-index-annotation \
  -o requirements.txt
```

If your project uses extras:
```bash
uv pip compile pyproject.toml \
  --python-platform linux \
  --extra server --extra tracing \
  --index https://console.redhat.com/api/pypi/public-rhai/rhoai/3.4/cpu-ubi9/simple/ \
  --index-strategy first-index \
  --emit-index-annotation \
  -o requirements.txt
```

If your requirements pin AIPCC-specific versions with release suffixes like `vllm==0.18.0+rhaiv.4`, you need to tell `uv` to allow pre-releases — it treats the `+rhaiv` local version segment as a pre-release and skips it by default. Prefer `--prerelease=if-necessary` over `--prerelease=allow`:

- **`--prerelease=if-necessary`** — only uses a pre-release when no stable version satisfies the constraint. This is safer for multi-arch builds because it avoids pulling release candidates that may only have wheels for a subset of architectures.
- **`--prerelease=allow`** — allows pre-releases for all packages, which can pull RC versions (e.g., `safetensors==0.8.0rc0`) that have wheels on some architectures but not others, causing builds to fail on the missing arch.

Use `--prerelease=allow` only if you specifically need an RC version. See [AIPCC: pre-release versions break multi-arch builds](#aipcc-pre-release-versions-break-multi-arch-builds) for details.

**Critical: `--index-url` must be a pip directive in requirements.txt.** Hermeto reads `--index-url` directives from requirements files to know where to download packages. The `--emit-index-annotation` flag only adds comments (e.g., `# from https://...`), which hermeto ignores — without an actual `--index-url` directive, hermeto defaults to PyPI and fetches `manylinux` wheels or sdists instead of AIPCC's `linux_*` wheels. Add `--index-url` to the top of your compiled requirements.txt:

```
--index-url https://console.redhat.com/api/pypi/public-rhai/rhoai/3.4/cpu-ubi9/simple/
```

> **`--emit-index-url` pitfall:** `uv pip compile --emit-index-url` does emit pip directives, but it gets the ordering wrong — PyPI is emitted as the primary `--index-url` and the custom index as `--extra-index-url`. This means pip (and hermeto) will prefer PyPI over AIPCC. If you use `--emit-index-url`, you must manually edit the output to remove the PyPI `--index-url` line and promote the AIPCC `--extra-index-url` to `--index-url`. It is simpler to omit `--emit-index-url` and add the `--index-url` line manually.

The `--index-strategy first-index` strategy prefers packages from the first index listed (AIPCC) and is the recommended approach. Some repos use `--index-strategy unsafe-best-match` instead, which picks the highest version across all indexes — this lets AIPCC's patched versions (e.g., `vllm==0.18.0+rhaiv.4`) win over PyPI's unpatched version numbers. However, `unsafe-best-match` can silently pull packages from PyPI when they are missing or lower-versioned on AIPCC, resulting in a mix of sources that is not supported by AIPCC (see the warning above about mixing indexes).

**Hermeto config for AIPCC:**

Since AIPCC only publishes wheels (no sdists), you must set `binary` in your hermeto config so hermeto knows to fetch wheels. List the specific architectures you build for rather than using `":all:"`:

```json
{
  "type": "pip",
  "path": ".",
  "requirements_files": ["requirements.txt"],
  "requirements_build_files": ["requirements-build.txt"],
  "binary": { "arch": "x86_64,aarch64,ppc64le,s390x" }
}
```

> **Avoid `":all:"` for AIPCC.** The `":all:"` shorthand fetches wheels for every platform variant — including i686 and musllinux — which inflates download size and time. List only the architectures your Konflux pipeline actually builds for (typically `x86_64,aarch64,ppc64le,s390x`).

Once the AIPCC base image is in place, no additional hermeto-specific Dockerfile modifications are needed. The pipeline's automatic `cachi2.env` injection sets `PIP_NO_INDEX=true` and `PIP_FIND_LINKS` to redirect pip to the prefetched cache. You will still need a pinned `requirements.txt` with the AIPCC `--index-url` annotation so hermeto knows where to download from, but the Dockerfile.konflux itself needs no manual env sourcing or prefetch mount paths. The Dockerfile's `pip install` commands do not need to reference the requirements file — they can install packages by name (e.g., `pip install mlserver` or `pip install pyspark==${VERSION}`). The requirements file tells hermeto what to prefetch; the pipeline's `PIP_FIND_LINKS` ensures pip finds the prefetched wheels regardless of how the install is invoked.

AIPCC base images come with build toolchains (gcc, make, python-devel, etc.) pre-installed, so you may not need RPM prefetch at all. Check whether your AIPCC base image already provides the system packages your build requires before adding `rpms.in.yaml`.

**Multi-variant builds:**

If your component builds for multiple accelerators (CPU, CUDA, ROCm), you need separate requirements files per variant (e.g., `requirements.cpu.txt`, `requirements.cuda.txt`) since each variant pulls from a different AIPCC index with different packages.

There are two approaches to structuring multi-variant builds:

- **Argfiles with a shared Dockerfile** — use `build-args/konflux.{variant}.conf` files to set the index URL, base image, and a flavor variable (e.g., `PYLOCK_FLAVOR=cpu`) that the Dockerfile uses to select `requirements.${PYLOCK_FLAVOR}.txt`. The notebooks component uses this pattern ([CPU config](https://github.com/red-hat-data-services/notebooks/blob/1e60d9cb49ec28740e89ac8ce5ded897f86f775b/jupyter/datascience/ubi9-python-3.12/build-args/konflux.cpu.conf), [CUDA config](https://github.com/red-hat-data-services/notebooks/blob/1e60d9cb49ec28740e89ac8ce5ded897f86f775b/jupyter/pytorch/ubi9-python-3.12/build-args/konflux.cuda.conf)).
- **Separate Dockerfiles per variant** — use `Dockerfile.konflux.cpu`, `Dockerfile.konflux.cuda`, `Dockerfile.konflux.rocm` with each pipeline pointing at a different Dockerfile. This is better when variants differ structurally (different stages, variant-specific build steps like ROCm solib linking). The distributed-workloads component uses this pattern.

**Transitional builds (`hermetic: false` with `prefetch-input`):**

You can configure `prefetch-input` in your pipeline while keeping `hermetic: false`. This prefetches dependencies for caching and reproducibility without cutting off network access — the build still succeeds even if some dependencies are not yet prefetched. This is useful when onboarding a component incrementally: get prefetch working first, validate that the prefetched cache covers everything, then flip `hermetic: true`. The notebooks repo uses this pattern for 17 of 18 components while AIPCC onboarding is in progress.

### Building from source for missing architectures

Some packages (like torch) have no wheels or sdists on PyPI for ppc64le/s390x but do publish source tarballs on their GitHub releases. You can prefetch these source tarballs through `requirements_build_files` so that pip can build from source on architectures that lack wheels, while still using PyPI wheels on x86_64/aarch64.

**1. Create a separate requirements file for the source package:**

`requirements-torch-source.txt`:
```
torch @ https://github.com/pytorch/pytorch/releases/download/v2.11.0/torch-2.11.0.tar.gz
```

**2. Generate the build dependencies:**

Run `pybuild-deps` against this file to discover the build backends needed to compile it:

```bash
uv run --python 3.12 --with pybuild-deps pybuild-deps compile \
  requirements-torch-source.txt -o requirements-build-torch.txt
```

This produces a file with cmake, ninja, numpy, cython, and other build backends that torch needs.

**3. Pin torch to the same version in your main requirements:**

The compiled `requirements.txt` must have `torch==2.11.0` as a version pin (not a URL reference) so that hermeto prefetches the PyPI wheels for architectures that have them (x86_64, aarch64). How you achieve this depends on your project setup:

- **In `requirements.in`:** add `torch==2.11.0`, then run `uv pip compile`
- **In `pyproject.toml`:** add `"torch==2.11.0"` to your dependencies, then compile with `uv pip compile pyproject.toml`
- **Inline:** pass the constraint directly: `uv pip compile requirements.in --constraint <(echo 'torch==2.11.0')`

**4. Configure hermeto to fetch both wheels and the source tarball:**

```json
{
  "type": "pip",
  "path": ".",
  "requirements_files": ["requirements.txt"],
  "requirements_build_files": [
    "requirements-build.txt",
    "requirements-build-torch.txt",
    "requirements-torch-source.txt"
  ],
  "binary": {
    "arch": "x86_64,aarch64,ppc64le,s390x"
  }
}
```

Everything lands in the same output directory. At install time:
- On **x86_64/aarch64**: pip finds the PyPI wheel in the cache and uses it directly
- On **ppc64le/s390x**: pip finds no wheel, discovers the source tarball in the cache, and builds from source using the prefetched build backends

This approach uses a single requirements.txt and a single hermeto config for all architectures. The source build on ppc64le/s390x will also need the native toolchain (compilers, -devel libraries) prefetched as RPMs — see [RPM Dependencies](#rpm-dependencies).

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
- `hermeto.json` -- for local testing only. The config is inlined in the Tekton PipelineRun prefetch task parameter.
- `.hermeto/` -- the prefetched output directory
- `.hermeto.env` -- the generated environment file

Consider adding these to `.dockerignore` as well to avoid accidentally including the prefetched output (which can be hundreds of MB) in the build context.

**Consider automating lockfile regeneration:**
- Lockfiles like `requirements.txt`, `requirements-build.txt`, and `rpms.lock.yaml` need to be regenerated when dependencies change. Consider adding a Makefile target, script, or CI job to automate this so the committed lockfiles stay in sync with your project's dependency declarations.

**Update in Tekton:**
- Copy the contents of `hermeto.json` into the prefetch task parameter in your `.tekton/` PipelineRun

## Common Gotchas

### Python: sigstore_models / uv-build / maturin build backend

Some Python packages (notably `sigstore_models`) declare `uv-build` as their build backend, which depends on maturin. Maturin can generate invalid Cargo lockfiles in a hermetic environment, causing the build to fail.

**Workaround:** Extract the sdist, strip the `[build-system]` section, and install directly. This works when the package is pure Python:

```bash
tar -xzf /cachi2/output/deps/pip/sigstore_models-0.0.6.tar.gz -C /tmp
cd /tmp/sigstore_models-0.0.6
sed -i '/^\[build-system\]$/,/^build-backend = "uv_build"$/d' pyproject.toml
python -m pip install .
```

You may also need to remove `uv-build` from `requirements-build.txt` since it is no longer needed.

### Python: uv ignores PIP_* environment variables

The pipeline's `cachi2.env` sets `PIP_NO_INDEX` and `PIP_FIND_LINKS` to redirect pip to the prefetched cache. However, [uv does not read `PIP_*` environment variables](https://docs.astral.sh/uv/pip/compatibility/#configuration-files-and-environment-variables) — it has its own equivalents (`UV_FIND_LINKS`, etc.).

If your Dockerfile uses `uv pip install`, pass the prefetch flags explicitly:

```dockerfile
RUN uv pip install --no-index --find-links "${PIP_FIND_LINKS}" \
    -r requirements.txt
```

`PIP_FIND_LINKS` is still set by `cachi2.env` — uv just needs it passed as a CLI argument. This also applies to `uv pip sync` and other `uv pip` subcommands.

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

Add these to both your `rpms.in.yaml` and the `microdnf install` line in your Dockerfile. If you only add them to the Dockerfile without declaring them in `rpms.in.yaml`, the hermetic build will fail because `microdnf` has no network access.

### Using permissive mode for mismatched lockfiles

Some Rust extensions ship with out-of-sync `Cargo.lock` / `Cargo.toml`. If `hermeto fetch-deps` fails due to lockfile mismatches or other non-fatal inconsistencies:

```bash
hermeto --mode permissive fetch-deps hermeto.json
```

This regenerates lockfiles instead of erroring out. Note that this reduces reproducibility -- the SBOM may not perfectly reflect what was built.

In a Konflux pipeline, set the `prefetch-mode` parameter to add `--mode permissive` to the hermeto invocation in the build:

```yaml
- name: prefetch-mode
  value: "permissive"
```

### Bad hashes from package indexes

Package indexes occasionally publish incorrect hashes for a package version. When this happens, `uv pip compile` or `uv export` records the bad hash in your requirements file, and hermeto or pip fails at install time because the downloaded file doesn't match.

**Workaround:** Strip the bad hash from the generated requirements file as a post-processing step. File a ticket with the index maintainer to get the hash corrected upstream, and remove the workaround once fixed. For example, using `perl` to remove a specific hash:

```bash
HASH="f2839f9c2c7e2dffc1bc5929a510e14ce0a946be9365fd1219e7ef342dae14f4"
perl -0777 -pi -e "s/ \\\\\n    --hash=sha256:${HASH}//g" requirements.txt
```

If you have a regeneration script (see [Alternative: `uv export` from `uv.lock`](#alternative-uv-export-from-uvlock)), add this step after the export so it runs automatically.

### AIPCC: duplicate wheels from build numbers

AIPCC publishes wheels with build numbers in the filename (e.g., `torch-2.10.0-2-cp312-cp312-linux_x86_64.whl` where `-2` is a build tag). When AIPCC rebuilds a package, the old build remains on the index alongside the new one. Hermeto fetches all available builds for a given version, which can significantly inflate the prefetch size.

**Workaround:** Add `--generate-hashes` to your `uv pip compile` command. The hashes pin to specific wheel files, so hermeto downloads only the exact builds your requirements reference rather than every build of that version. This also improves reproducibility.

### AIPCC: pre-release versions break multi-arch builds

AIPCC may publish release candidate versions (e.g., `safetensors==0.8.0rc0`) for some architectures before others. If `uv pip compile --prerelease=allow` picks one of these RC versions, the compiled requirements work on architectures that have the RC wheel but fail on architectures that don't — typically s390x or ppc64le, which receive new builds later.

**Example:** `safetensors==0.8.0rc0` had wheels for x86_64, aarch64, and ppc64le on the AIPCC index but not s390x (which only had `0.7.0`). The build succeeded on three arches and failed on s390x with `No matching distribution found for safetensors==0.8.0rc0`.

**Fix:** Use `--prerelease=if-necessary` instead of `--prerelease=allow`. This tells `uv` to only use a pre-release version when no stable version satisfies the constraint, which avoids accidentally picking RC versions that lack full architecture coverage:

```bash
uv pip compile pyproject.toml \
  --python-platform linux \
  --python-version 3.12 \
  --index https://console.redhat.com/api/pypi/public-rhai/rhoai/3.5-EA1/cpu-ubi9/simple/ \
  --index-strategy first-index \
  --prerelease=if-necessary \
  --emit-index-annotation \
  -o requirements.txt
```

If you need a specific RC version, pin it explicitly in your constraints instead of using `--prerelease=allow` globally.

**Diagnosis:** When a multi-arch build fails with `No matching distribution found` for a package with an RC version number, check whether the AIPCC index has that version for all target architectures. Browse the index at `https://console.redhat.com/api/pypi/public-rhai/rhoai/{release}/{variant}/simple/{package}/` and look for wheels with your failing architecture's platform tag (e.g., `linux_s390x`).

### macOS: sed command for Dockerfile injection

The sed command in [step 2](#2-generate-the-environment-file-and-modify-the-dockerfile) uses the `M` (multiline) flag, which is a GNU extension. macOS ships BSD sed, which does not support it.

**Fix:** Install GNU sed with `brew install gnu-sed` and use `gsed` instead of `sed` in the command.

### Organizing workarounds

If you have multiple hermetic build fixes, collect them in a shell script (e.g., `hermetic_fixes.sh`) rather than bloating the Dockerfile. This makes it clear which steps are temporary workarounds vs. permanent build logic:

```dockerfile
COPY ./hermetic_fixes.sh ./
RUN ./hermetic_fixes.sh
```

Document each fix with the root cause and the condition under which it can be removed.

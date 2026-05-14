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

The first step is to create a correct hermeto config. This is a JSON array of package manager objects, each with a `type` field and manager-specific options. In this guide, we save it to a file called `hermeto.json` for local testing, but in your Konflux build pipeline the JSON is typically inlined as a parameter to the prefetch task.

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

The key fields are `packages` (comma-separated names, or `:all:` to try wheels for everything) and `arch` (comma-separated architectures, default `"x86_64"`). When `packages` is `:all:` (the default), hermeto prefers wheels but falls back to sdists. When you name specific packages, hermeto *fails* if no matching wheel exists. See the [hermeto pip docs](https://hermetoproject.github.io/hermeto/latest/pip/) for additional filter fields (`os`, `py_version`, `py_impl`, `abi`, `platform`).

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
- **Direct downloads** -- curl, wget, git clone, or any script that fetches from the internet. These can often be handled with the [generic fetcher](#generic).

Each network access point maps to a hermeto package manager config (see [Configuring hermeto.json](#configuring-hermetojson)) or needs a manual workaround.

Only network access in the Dockerfile matters. A repo may contain lockfiles (e.g., `package-lock.json` for a documentation site, or `requirements.txt` for a test suite) that are never referenced by the container build -- these do not need hermeto entries. The Dockerfile is your guide, not the repo's file listing.

Multiple commands using the same package manager still map to a single hermeto entry. For example, a Dockerfile might run `npm ci` for a full install during the build stage and then `npm install --omit=dev` to prune to production dependencies. Both draw from the same prefetched cache -- hermeto prefetches everything in the lockfile, and each `npm` command finds what it needs regardless of flags like `--omit=dev` or `--ignore-scripts`.

If the project has multiple Dockerfiles, identify which one is the target for hermetic builds. Also check whether the Dockerfile requires additional build inputs (argfiles, build-args, `.env` files) that affect what gets installed.

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

### Generating requirements-build.txt

Source distributions (sdists) need build backends (hatchling, maturin, pdm-backend, etc.) to compile. Use [pybuild-deps](https://pypi.org/project/pybuild-deps/) to discover these automatically:

```bash
uv run --python 3.9 --with pybuild-deps pybuild-deps compile \
  requirements.txt -o requirements-build.txt
```

Match the `--python` version to your target image. This file is needed if any of your dependencies are installed from source distributions (sdists). If a package has no wheel for your target architecture, you'll need this file along with the native toolchain RPMs to build from source -- or use a custom index like AIPCC that has prebuilt wheels (see [Using AIPCC wheels](#using-aipcc-wheels)).

### Using AIPCC wheels

[AIPCC](https://packages.redhat.com/domains/public-rhai/distributions) (AI Platform Core Components) publishes prebuilt Python wheels for all target architectures (x86_64, aarch64, ppc64le, s390x) and accelerator variants (CPU, CUDA, ROCm). Using AIPCC wheels eliminates the need to build packages from source on architectures that lack public PyPI wheels. Several RHOAI components already use AIPCC, including notebooks, mlflow, and mlserver.

**Important:** AIPCC wheels are built with external dependencies on system libraries installed in the corresponding AIPCC base images. Unlike upstream `manylinux` wheels which bundle their dependencies, AIPCC wheels will not work without the matching base image. Do not mix AIPCC wheels with wheels from pypi.org -- ABI incompatibilities between bundled and external dependencies can cause crashes, incorrect output, or libraries that fail to load. Each AIPCC index must be used with its corresponding base image. Pure-Python packages from PyPI are lower risk to mix in since they have no compiled components, but this is unsupported by AIPCC -- if a package you need is missing, [request it](#requesting-packages) instead.

> **Note:** Some components (e.g., mlflow) temporarily prefetch a small number of packages from public PyPI alongside AIPCC -- typically pure-Python packages or compiled extensions that don't touch the accelerator stack (e.g., `psycopg2`). This can work as a short-term workaround, but the proper fix is to get the missing packages added to AIPCC so everything comes from a single, supported index.

AIPCC provides separate indexes per RHOAI release and accelerator variant. Browse available indexes at [packages.redhat.com](https://packages.redhat.com/domains/public-rhai/distributions). For RHOAI 3.4:

| Variant | Index URL | Base Image |
|---------|-----------|------------|
| CPU | `.../rhoai/3.4/cpu-ubi9/simple/` | `quay.io/aipcc/base-images/cpu:3.4.0-...` |
| CUDA 12.9 | `.../rhoai/3.4/cuda12.9-ubi9/simple/` | `quay.io/aipcc/base-images/cuda-12.9-el9.6:3.4.0-...` |
| CUDA 13.0 | `.../rhoai/3.4/cuda13.0-ubi9/simple/` | `quay.io/aipcc/base-images/cuda-13.0-el9.6:3.4.0-...` |
| ROCm 6.4 | `.../rhoai/3.4/rocm6.4-ubi9/simple/` | `quay.io/aipcc/base-images/rocm-6.4-el9.6:3.4.0-...` |

The full index URL prefix is `https://console.redhat.com/api/pypi/public-rhai/`. The base images are pre-configured so that `pip` and `uv` pull from the matching index automatically.

To request a new package or version, use the [AIPCC package request form](https://dashboard.aipcc.redhat.com/package-request) or file a Jira under [AIPCC-1](https://issues.redhat.com/browse/AIPCC-1).

**Getting started with AIPCC:**

Start by getting your build working non-hermetically using the AIPCC base image and its pre-configured index. Once your `pip install` succeeds, freeze your dependencies with `uv pip compile` to produce a pinned requirements file that hermeto can prefetch from the AIPCC index.

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

**Hermeto config for AIPCC:**

Since AIPCC only publishes wheels (no sdists), you must set `binary` in your hermeto config so hermeto knows to fetch wheels. Use `":all:"` to accept wheels for all packages:

```json
{
  "type": "pip",
  "path": ".",
  "requirements_files": ["requirements.txt"],
  "binary": { "arch": ":all:" }
}
```

Like Go projects with `gomod`, AIPCC-only pip projects often need zero hermetic-specific Dockerfile changes. The pipeline's automatic `cachi2.env` injection sets `PIP_NO_INDEX=true` and `PIP_FIND_LINKS` to redirect pip to the prefetched cache. You will still need a pinned `requirements.txt` with the AIPCC `--index-url` annotation so hermeto knows where to download from, but the Dockerfile.konflux itself typically requires only Konflux-general changes (base image, labels) — no manual env sourcing or mount paths.

**Multi-variant builds:**

If your component builds for multiple accelerators (CPU, CUDA, ROCm), you may want to maintain separate requirements files per variant (e.g., `requirements.cpu.txt`, `requirements.cuda.txt`) and use build-args to select the right one at build time. The notebooks component does this with a `build-args/konflux.{variant}.conf` file that sets the index URL and base image for each variant (e.g., [CPU config](https://github.com/red-hat-data-services/notebooks/blob/1e60d9cb49ec28740e89ac8ce5ded897f86f775b/jupyter/datascience/ubi9-python-3.12/build-args/konflux.cpu.conf), [CUDA config](https://github.com/red-hat-data-services/notebooks/blob/1e60d9cb49ec28740e89ac8ce5ded897f86f775b/jupyter/pytorch/ubi9-python-3.12/build-args/konflux.cuda.conf)).

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

other ways of specifying context

```
context:
  containerfile:
    file: Dockerfiles/controller.Dockerfile.konflux
    imagePattern: ubi9/ubi-minimal
```

The `contentOrigin` section can also be inlined:

```
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
```

The `context.containerfile` field tells the lockfile generator which Dockerfile stage needs these packages, so it can resolve the correct base image repositories.

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

Some Rust extensions ship with out-of-sync `Cargo.lock` / `Cargo.toml`. If `hermeto fetch-deps cargo` fails due to lockfile mismatches:

```bash
hermeto --mode permissive fetch-deps cargo
```

This regenerates the lockfile instead of erroring out. Note that this reduces reproducibility -- the SBOM may not perfectly reflect what was built.

### Organizing workarounds

If you have multiple hermetic build fixes, collect them in a shell script (e.g., `hermetic_fixes.sh`) rather than bloating the Dockerfile. This makes it clear which steps are temporary workarounds vs. permanent build logic:

```dockerfile
COPY ./hermetic_fixes.sh ./
RUN ./hermetic_fixes.sh
```

Document each fix with the root cause and the condition under which it can be removed.

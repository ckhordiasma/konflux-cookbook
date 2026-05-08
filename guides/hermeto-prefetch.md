# Using Hermeto to Prefetch Dependencies for Hermetic Konflux Builds

## What is Hermeto

Hermeto is a CLI tool that pre-fetches project dependencies so that container builds can run without network access (hermetic builds). It downloads all declared dependencies from lockfiles into a local output directory, generates an SBOM, and produces environment files that configure package managers to use the local cache instead of reaching out to the internet. In Konflux, Hermeto replaces the older Cachi2 tool -- the output directory and environment file still use the `/cachi2/` paths for backward compatibility.

## Installing Hermeto

### Container 

```bash
alias hermeto='podman run --rm -ti -v "$PWD:$PWD:z" -w "$PWD" \
  ghcr.io/hermetoproject/hermeto:latest'
```

This mounts your project directory into the container so Hermeto can read lockfiles and write output.

## Configuring `.hermeto.json`

The hermeto config defines which package managers to prefetch and how. It is a JSON array of package manager objects, each with a `type` field and manager-specific options. In this guide, we save it to a file called `.hermeto.json` for local testing, but in your Konflux build pipeline the JSON is typically inlined as a parameter to the prefetch task.

For local testing:

```bash
hermeto fetch-deps \
  --source . \
  --output .hermeto \
  .hermeto.json
```

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

### pip (Python)

[Hermeto pip docs](https://hermetoproject.github.io/hermeto/latest/pip/)

Hermeto requires a fully resolved `requirements.txt` with all transitive dependencies pinned to exact versions (e.g., `package==1.2.3`). Hashes are strongly recommended but optional for PyPI packages. For dependencies fetched via HTTPS URLs, exactly one `--hash` is required. See [Python Requirements](#python-requirements) for how to generate these files.

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

Even with binary wheels enabled, keep `requirements_build_files` -- not all packages publish wheels for every architecture (e.g., ppc64le, s390x), so hermeto will fall back to building from source and needs the build dependencies.

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

## Basic Usage

The core workflow has three steps: fetch dependencies, generate the environment file, and inject any config files package managers need.

### 1. Fetch dependencies

Assuming you are in the root level of your project directory:

```bash
hermeto fetch-deps \
  --source . \
  --output .hermeto \
  .hermeto.json
```

You can also pass the package manager config inline as a string or simple keyword:

```bash
hermeto fetch-deps \
  --source . \
  --output .hermeto \
  pip
```

### 2. Generate the environment file

```bash
hermeto generate-env .hermeto/ -o .hermeto.env \
  --for-output-dir /cachi2/output
```

The `--for-output-dir` flag sets the absolute path where the output will be mounted inside the build container. For Konflux builds this is `/cachi2/output`.

### 3. Inject configuration files

```bash
hermeto inject-files ./.hermeto --for-output-dir /cachi2/output
```

This modifies project files (e.g., creates `.cargo/config.toml` for Cargo) so that package managers point at the local cache. Run this before committing -- it may overwrite files in your working tree.

### 4. Test locally with a hermetic build

```bash
podman build . \
  --volume "$(realpath ./.hermeto)":/cachi2/output:Z \
  --volume "$(realpath ./.hermeto.env)":/cachi2/cachi2.env:Z \
  --network none \
  -f Dockerfile.konflux
```

The `--network none` flag proves that all dependencies are actually prefetched.

## Makefile-Based Workflow

For iterative development, a Makefile lets you run individual stages without re-running everything from scratch. The cookbook includes a parameterized Makefile at `scripts/Makefile.hermeto` that you can copy into your project and configure.

### Setup

Copy the Makefile and configure the variables at the top:

```bash
cp /path/to/konflux-cookbook/scripts/Makefile.hermeto .
```

Or override variables on the command line:

```bash
make -f Makefile.hermeto PYTHON_VERSION=3.12 DOCKERFILE=Dockerfile.konflux build
```

### Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PYTHON_VERSION` | `3.9` | Target Python version (must match base image) |
| `REQUIREMENTS_IN` | `requirements.in` | Space-separated list of `.in` files to compile |
| `HERMETO_CONFIG` | `.hermeto.json` | Path to hermeto JSON config |
| `DOCKERFILE` | `Dockerfile.konflux` | Source Dockerfile to transform |
| `BUILD_CONTEXT` | `.` | Docker build context directory |
| `HERMETO_OUTPUT` | `.hermeto` | Output directory for prefetched deps |

### Available Targets

Run any stage independently -- Make tracks file timestamps and skips work that's already done:

```bash
make -f Makefile.hermeto pip-compile   # resolve .in -> .txt
make -f Makefile.hermeto build-deps    # find build backends (pybuild-deps)
make -f Makefile.hermeto rpm-lock      # generate rpms.lock.yaml
make -f Makefile.hermeto hermeto       # prefetch everything into .hermeto/
make -f Makefile.hermeto dockerfile    # generate hermetic Dockerfile
make -f Makefile.hermeto build         # full offline podman build
make -f Makefile.hermeto clean         # remove generated artifacts
```

The `build` target depends on all upstream stages, so `make build` runs everything end-to-end. If you've already run `pip-compile` and only changed `rpms.in.yaml`, running `make build` will skip pip compilation and only re-run what changed.

### Testing on Remote Architectures

To test hermetic builds on a different CPU architecture (e.g., x86_64 from an ARM Mac), sync to a remote host and run just the build stage:

```bash
# On your local machine: run pip-compile and hermeto (these don't need target arch)
make -f Makefile.hermeto hermeto dockerfile

# Sync to a remote host
rsync -az --delete . user@remote-host:/tmp/myproject

# On the remote host: only podman is needed, not uv
ssh -t user@remote-host 'cd /tmp/myproject && make -f Makefile.hermeto build'
```

The `build` target only requires `podman` -- it doesn't need `uv` or other tools that are only used during the resolution stages. This makes it easy to test on minimal hosts.

## Modifying Your Dockerfile.konflux

A Konflux hermetic build mounts the prefetched dependencies at `/cachi2/output` and the environment file at `/cachi2/cachi2.env`. Your `Dockerfile.konflux` needs to source that env file before any install commands.

Here is the typical pattern:

```dockerfile
FROM registry.access.redhat.com/ubi9/python-312-minimal AS base

USER 0

# Source cachi2.env so pip/cargo find the prefetched deps.
# Install system packages in the same RUN to keep layers small.
RUN . /cachi2/cachi2.env && \
    microdnf install -y gcc make python3.12-devel cargo && \
    microdnf clean all

WORKDIR /app
COPY ./requirements.txt ./

# Install Python dependencies from the prefetched cache
RUN . /cachi2/cachi2.env && \
    python -m pip install -r requirements.txt

COPY . .
USER 1001
ENTRYPOINT ["python", "-m", "myapp"]
```

Key points:

- **Source the env file in every `RUN` that installs dependencies.** Each `RUN` is a separate shell, so `. /cachi2/cachi2.env` must appear in each one that calls pip, cargo, npm, etc.
- **Do not combine sourcing with `&&` after a `COPY`.** The env file is mounted by the build system, not copied from your repo.
- For **Cargo + pip** projects (e.g., Python packages with Rust extensions), the env file configures both pip and cargo at once.

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

Match the `--python` version to your target image. Even if you enable binary wheels, keep `requirements-build.txt` -- not all packages publish wheels for every architecture (e.g., ppc64le, s390x), so hermeto may fall back to building from source.

### Using AIPCC wheels

```
uv pip compile pyproject.toml --python-platform linux  --index https://console.redhat.com/api/pypi/public-rhai/rhoai/3.4/cpu-ubi9-test/simple/ --index-strategy first-index --emit-index-annotation
```

If you want to include extras, add them as command flags:
```
uv pip compile pyproject.toml --python-platform linux --extra sdd --extra jailbreak --extra openai --extra nvidia --extra tracing --extra models --extra multilingual --extra server  --index https://console.redhat.com/api/pypi/public-rhai/rhoai/3.4/cpu-ubi9-test/simple/ --index-strategy first-index --emit-index-annotation
```

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

# Using Hermeto to Prefetch Dependencies for Hermetic Konflux Builds

## What is Hermeto

Hermeto is a CLI tool that pre-fetches project dependencies so that container builds can run without network access (hermetic builds). It downloads all declared dependencies from lockfiles into a local output directory, generates an SBOM, and produces environment files that configure package managers to use the local cache instead of reaching out to the internet. In Konflux, Hermeto replaces the older Cachi2 tool -- the output directory and environment file still use the `/cachi2/` paths for backward compatibility.

## Installing Hermeto

### pip

```bash
pip install hermeto
```

### Container (no local install needed)

```bash
alias hermeto='podman run --rm -ti -v "$PWD:$PWD:z" -w "$PWD" \
  ghcr.io/hermetoproject/hermeto:latest'
```

This mounts your project directory into the container so Hermeto can read lockfiles and write output.

## Basic Usage

The core workflow has three steps: fetch dependencies, generate the environment file, and inject any config files package managers need.

### 1. Fetch dependencies

```bash
hermeto fetch-deps \
  --source ./my-repo \
  --output ./hermeto-output \
  pip
```

The package manager argument can be a simple string (`pip`, `cargo`, `gomod`, `npm`, `yarn`, `bundler`, `rpm`) or a JSON object for more control:

```bash
hermeto fetch-deps \
  --source ./my-repo \
  --output ./hermeto-output \
  '{"type": "pip", "path": ".", "requirements_files": ["requirements.txt"]}'
```

To fetch multiple package managers at once, pass a JSON array:

```bash
hermeto fetch-deps \
  --source ./my-repo \
  --output ./hermeto-output \
  '[{"type": "pip", "path": "."}, {"type": "cargo", "path": "."}]'
```

### 2. Generate the environment file

```bash
hermeto generate-env ./hermeto-output -o ./hermeto.env \
  --for-output-dir /cachi2/output
```

The `--for-output-dir` flag sets the absolute path where the output will be mounted inside the build container. For Konflux builds this is `/cachi2/output`.

### 3. Inject configuration files

```bash
hermeto inject-files ./hermeto-output --for-output-dir /cachi2/output
```

This modifies project files (e.g., creates `.cargo/config.toml` for Cargo) so that package managers point at the local cache. Run this before committing -- it may overwrite files in your working tree.

### 4. Test locally with a hermetic build

```bash
podman build . \
  --volume "$(realpath ./hermeto-output)":/cachi2/output:Z \
  --volume "$(realpath ./hermeto.env)":/cachi2/cachi2.env:Z \
  --network none \
  -f Dockerfile.konflux
```

The `--network none` flag proves that all dependencies are actually prefetched.

## Package Manager Examples

### pip (Python)

Hermeto requires a fully resolved `requirements.txt` with pinned versions. Generate one with hashes for security:

```bash
pip-compile pyproject.toml --generate-hashes -o requirements.txt
```

If your project has packages that build from source (sdists), you also need a build-dependencies file:

```bash
pybuild-deps compile --generate-hashes -o requirements-build.txt requirements.txt
```

Then fetch:

```bash
hermeto fetch-deps \
  --source . \
  --output ./hermeto-output \
  '{
    "type": "pip",
    "path": ".",
    "requirements_files": ["requirements.txt"],
    "requirements_build_files": ["requirements-build.txt"]
  }'
```

**Wheel filtering** -- to prefetch binary wheels for a specific platform instead of only sdists:

```bash
hermeto fetch-deps \
  --source . \
  --output ./hermeto-output \
  '{
    "type": "pip",
    "path": ".",
    "requirements_files": ["requirements.txt"],
    "binary": {
      "packages": "tensorflow",
      "os": "linux",
      "arch": "x86_64",
      "py_version": 312
    }
  }'
```

### cargo (Rust)

Ensure both `Cargo.toml` and `Cargo.lock` are present and in sync:

```bash
hermeto fetch-deps \
  --source . \
  --output ./hermeto-output \
  cargo
```

After fetching, run `inject-files` to generate `.cargo/config.toml` which redirects Cargo to the local vendor directory:

```bash
hermeto inject-files ./hermeto-output --for-output-dir /cachi2/output
```

Copy `.cargo/config.toml` into your container image alongside `Cargo.toml` and `Cargo.lock`.

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

The `context.containerfile` field tells the lockfile generator which Dockerfile stage needs these packages, so it can resolve the correct base image repositories.

### Generating rpms.lock.yaml

Use [rpm-lockfile-prototype](https://github.com/konflux-ci/rpm-lockfile-prototype) to resolve and lock RPM versions:

```bash
rpm-lockfile-prototype rpms.in.yaml
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

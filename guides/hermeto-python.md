# Python and AIPCC Guide for Hermetic Builds

This guide covers Python-specific workflows for hermetic Konflux builds: generating pinned requirements files, using AIPCC prebuilt wheels, and building from source on architectures that lack wheels. For the general hermeto workflow (config format, fetch-deps, local testing, Dockerfile injection), see the [main hermeto guide](hermeto-prefetch.md).

The hermeto [pip config reference](hermeto-prefetch.md#pip-python) in the main guide covers the `hermeto-test.json` fields (`requirements_files`, `requirements_build_files`, `binary`). This guide covers what goes *into* those files.

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

## Using AIPCC Wheels

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

AIPCC provides separate indexes per RHOAI release and accelerator variant. Browse [packages.redhat.com](https://packages.redhat.com/domains/public-rhai/distributions) for the current list — the versions and variants below were current as of RHOAI 3.4 and may have changed since:

| Variant | Index URL | Base Image |
|---------|-----------|------------|
| CPU | `.../rhoai/3.4/cpu-ubi9/simple/` | `quay.io/aipcc/base-images/cpu:3.4.0-...` |
| CUDA 12.9 | `.../rhoai/3.4/cuda12.9-ubi9/simple/` | `quay.io/aipcc/base-images/cuda-12.9-el9.6:3.4.0-...` |
| CUDA 13.0 | `.../rhoai/3.4/cuda13.0-ubi9/simple/` | `quay.io/aipcc/base-images/cuda-13.0-el9.6:3.4.0-...` |
| ROCm 6.4 | `.../rhoai/3.4/rocm6.4-ubi9/simple/` | `quay.io/aipcc/base-images/rocm-6.4-el9.6:3.4.0-...` |

The full index URL prefix is `https://console.redhat.com/api/pypi/public-rhai/`. The base images are pre-configured so that `pip` and `uv` pull from the matching index automatically.

### Requesting packages

If a package you need is missing from the AIPCC index, submit a request through the [AIPCC package request form](https://dashboard.aipcc.redhat.com/package-request) (requires Red Hat VPN). See the [package onboarding docs](https://package-onboarding-0af11e.gitlab.io/) for the full process.

You need to request your project's **dependencies**, not the project itself. If your Dockerfile does `pip install .` to build the project from source, the project's code is installed locally — only its dependencies need to be on the AIPCC index. If your project has an upstream PyPI equivalent (e.g., `mlflow`), you can submit the upstream package name to get its full dependency tree onboarded, even if you don't use the AIPCC-built wheel yourself. If your midstream fork has different dependencies than upstream, request the missing packages individually.

Key points:
- **One submission per PyPI package** — sub-packages with separate PyPI entries need separate requests
- **Transitive dependencies are handled automatically** — only request top-level packages
- **The form handles updates and rebuilds too** — use it for new versions, not just new packages
- **Include a target date and release commitment** if urgent — simple packages can be same-day, complex native builds take longer

Ask in [#forum-aipcc](https://redhat-internal.slack.com/archives/C07JX0EMKCZ) for general questions or [#forum-aipcc-wheels](https://redhat-internal.slack.com/archives/C079FE5H94J) for wheel-specific issues.

### Getting started with AIPCC

Start by getting your build working non-hermetically using the AIPCC base image and its pre-configured index. Once your `pip install` succeeds, freeze your dependencies with `uv pip compile` to produce a pinned requirements file that hermeto can prefetch from the AIPCC index.

The `red-hat-data-services/notebooks` repo has already onboarded to AIPCC and shows working combinations of base images and index URLs across RHOAI releases and accelerator variants.

Point `uv pip compile` at the AIPCC index with `--default-index` and `--index-strategy first-index`. Use `--emit-index-url` so the compiled output includes an `--index-url` pip directive that hermeto can read. `--emit-index-annotation` is optional but useful -- it annotates each package with the index it was resolved from, making it easy to trace sourcing:

```bash
uv pip compile requirements.in \
  --python-platform linux \
  --python-version 3.12 \
  --default-index https://console.redhat.com/api/pypi/public-rhai/rhoai/3.4/cpu-ubi9/simple/ \
  --index-strategy first-index \
  --emit-index-url \
  --emit-index-annotation \
  -o requirements.txt
```

If your project uses extras:
```bash
uv pip compile pyproject.toml \
  --python-platform linux \
  --extra server --extra tracing \
  --default-index https://console.redhat.com/api/pypi/public-rhai/rhoai/3.4/cpu-ubi9/simple/ \
  --index-strategy first-index \
  --emit-index-url \
  --emit-index-annotation \
  -o requirements.txt
```

> **Why `--default-index` instead of `--index`?** The `--default-index` flag replaces PyPI as the primary index, so `--emit-index-url` emits it as the `--index-url` directive in the output. If you use `--index` instead, uv treats it as a supplementary index and PyPI remains the default — `--emit-index-url` then emits PyPI as `--index-url` and your custom index as `--extra-index-url`, which causes hermeto (and pip) to prefer PyPI over AIPCC.

If your constraints explicitly pin AIPCC-specific versions with local version segments like `vllm==0.18.0+rhaiv.4`, uv will skip them by default. Add `--prerelease=if-necessary` to allow them. Prefer this over `--prerelease=allow`:

- **`--prerelease=if-necessary`** — only uses a pre-release when no stable version satisfies the constraint. This is safer for multi-arch builds because it avoids pulling release candidates that may only have wheels for a subset of architectures.
- **`--prerelease=allow`** — allows pre-releases for all packages, which can pull RC versions (e.g., `safetensors==0.8.0rc0`) that have wheels on some architectures but not others, causing builds to fail on the missing arch.

Use `--prerelease=allow` only if you specifically need an RC version. See [AIPCC: pre-release versions break multi-arch builds](#aipcc-pre-release-versions-break-multi-arch-builds) for details.

**Consider `--no-strip-markers`** if your dependencies include platform-specific packages. Some dependencies are only needed on certain architectures — for example, `triton` is a torch dependency only on `platform_machine != "s390x"`. By default, `uv pip compile` strips environment markers from the output, producing a flat list like `triton==3.6.0` that pip will try to install everywhere. Adding `--no-strip-markers` preserves the markers in the output (e.g., `triton==3.6.0 ; platform_machine != 's390x'`), so pip skips arch-specific packages on architectures that don't need them.

**Verifying multi-arch compatibility:**

The flags above (`--prerelease=if-necessary`, `--no-strip-markers`, `--default-index`) handle the common cases, but AIPCC index coverage can change between releases. To be certain your requirements.txt will install on all target architectures, run `uv pip compile` on a machine of each target architecture (e.g., [Beaker VMs](beaker-vm.md)) and compare the resolved versions. If every arch resolves to the same package versions, your requirements.txt is safe. If they diverge, the differing package likely has an RC or newer version on some arches but not others — constrain it to the version available everywhere, or use `--prerelease=if-necessary` to avoid the RC.

As a last resort, if you cannot get a single requirements.txt that resolves identically on all architectures, generate a separate requirements file per arch (e.g., `requirements-x86_64.txt`, `requirements-s390x.txt`) and pass them all to hermeto:

```json
{
  "type": "pip",
  "path": ".",
  "requirements_files": [
    "requirements-x86_64.txt",
    "requirements-aarch64.txt",
    "requirements-ppc64le.txt",
    "requirements-s390x.txt"
  ],
  "binary": { "arch": "x86_64,aarch64,ppc64le,s390x" }
}
```

Hermeto merges all the files and fetches the union of dependencies. At install time, pip on each architecture installs only the packages that match its platform. The Dockerfile selects the right file at build time using `$(uname -m)`:

```dockerfile
COPY requirements-*.txt ./
RUN pip install --no-cache-dir -r requirements-$(uname -m).txt
```

This is the most reliable approach but adds maintenance burden — you must recompile each file when dependencies change. Prefer fixing the root cause (constraining versions, using `--prerelease=if-necessary`) and use per-arch files only for arches that genuinely need different versions.

**Critical: `--index-url` must be a pip directive in requirements.txt.** Hermeto reads `--index-url` directives from requirements files to know where to download packages. The `--emit-index-annotation` flag only adds comments (e.g., `# from https://...`), which hermeto ignores — without an actual `--index-url` directive, hermeto defaults to PyPI and fetches `manylinux` wheels or sdists instead of AIPCC's `linux_*` wheels. Using `--default-index` with `--emit-index-url` (as shown above) handles this automatically. If you omit `--emit-index-url`, add `--index-url` to the top of your compiled requirements.txt manually:

```
--index-url https://console.redhat.com/api/pypi/public-rhai/rhoai/3.4/cpu-ubi9/simple/
```

The `--index-strategy first-index` strategy prefers packages from the first index listed (AIPCC) and is the recommended approach. Some repos use `--index-strategy unsafe-best-match` instead, which picks the highest version across all indexes — this lets AIPCC's patched versions (e.g., `vllm==0.18.0+rhaiv.4`) win over PyPI's unpatched version numbers. However, `unsafe-best-match` can silently pull packages from PyPI when they are missing or lower-versioned on AIPCC, resulting in a mix of sources that is not supported by AIPCC (see the warning above about mixing indexes).

### Hermeto config for AIPCC

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

> **`":all:"` works but downloads unnecessary platform variants** (i686, musllinux), which inflates download size and time. Listing only the architectures your Konflux pipeline actually builds for (typically `x86_64,aarch64,ppc64le,s390x`) keeps prefetch faster and smaller.

Once the AIPCC base image is in place, no additional hermeto-specific Dockerfile modifications are needed. The pipeline's automatic `cachi2.env` injection sets `PIP_NO_INDEX=true` and `PIP_FIND_LINKS` to redirect pip to the prefetched cache. You will still need a pinned `requirements.txt` with the AIPCC `--index-url` annotation so hermeto knows where to download from, but the Dockerfile.konflux itself needs no manual env sourcing or prefetch mount paths. The Dockerfile's `pip install` commands do not need to reference the requirements file — they can install packages by name (e.g., `pip install mlserver` or `pip install pyspark==${VERSION}`). The requirements file tells hermeto what to prefetch; the pipeline's `PIP_FIND_LINKS` ensures pip finds the prefetched wheels regardless of how the install is invoked.

AIPCC base images come with build toolchains (gcc, make, python-devel, etc.) pre-installed, so you may not need RPM prefetch at all. Check whether your AIPCC base image already provides the system packages your build requires before adding `rpms.in.yaml`.

### Multi-variant builds

If your component builds for multiple accelerators (CPU, CUDA, ROCm), you need separate requirements files per variant (e.g., `requirements.cpu.txt`, `requirements.cuda.txt`) since each variant pulls from a different AIPCC index with different packages.

There are two approaches to structuring multi-variant builds:

- **Argfiles with a shared Dockerfile** — use `build-args/konflux.{variant}.conf` files to set the index URL, base image, and a flavor variable (e.g., `PYLOCK_FLAVOR=cpu`) that the Dockerfile uses to select `requirements.${PYLOCK_FLAVOR}.txt`. The notebooks component uses this pattern ([CPU config](https://github.com/red-hat-data-services/notebooks/blob/1e60d9cb49ec28740e89ac8ce5ded897f86f775b/jupyter/datascience/ubi9-python-3.12/build-args/konflux.cpu.conf), [CUDA config](https://github.com/red-hat-data-services/notebooks/blob/1e60d9cb49ec28740e89ac8ce5ded897f86f775b/jupyter/pytorch/ubi9-python-3.12/build-args/konflux.cuda.conf)).
- **Separate Dockerfiles per variant** — use `Dockerfile.konflux.cpu`, `Dockerfile.konflux.cuda`, `Dockerfile.konflux.rocm` with each pipeline pointing at a different Dockerfile. This is better when variants differ structurally (different stages, variant-specific build steps like ROCm solib linking). The distributed-workloads component uses this pattern.

### Transitional builds

You can configure `prefetch-input` in your pipeline while keeping `hermetic: false`. This prefetches dependencies for caching and reproducibility without cutting off network access — the build still succeeds even if some dependencies are not yet prefetched. This is useful when onboarding a component incrementally: get prefetch working first, validate that the prefetched cache covers everything, then flip `hermetic: true`. The notebooks repo uses this pattern for 17 of 18 components while AIPCC onboarding is in progress.

## Building from Source for Missing Architectures

Some packages have no wheels or sdists on PyPI for ppc64le/s390x but do publish source tarballs on their GitHub releases. You can prefetch these source tarballs through `requirements_build_files` so that pip can build from source on architectures that lack wheels, while still using PyPI wheels on x86_64/aarch64. This pattern works for any package with a source tarball — from small Cython extensions to large frameworks like torch (used as the example below).

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

This approach uses a single requirements.txt and a single hermeto config for all architectures. The source build on ppc64le/s390x will also need the native toolchain (compilers, -devel libraries) prefetched as RPMs — see [RPM Dependencies](hermeto-prefetch.md#rpm-dependencies).

## Common Gotchas

### sigstore_models / uv-build / maturin build backend

Some Python packages (notably `sigstore_models`) declare `uv-build` as their build backend, which depends on maturin. Maturin can generate invalid Cargo lockfiles in a hermetic environment, causing the build to fail.

**Workaround:** Extract the sdist, strip the `[build-system]` section, and install directly. This works when the package is pure Python:

```bash
tar -xzf /cachi2/output/deps/pip/sigstore_models-0.0.6.tar.gz -C /tmp
cd /tmp/sigstore_models-0.0.6
sed -i '/^\[build-system\]$/,/^build-backend = "uv_build"$/d' pyproject.toml
python -m pip install .
```

You may also need to remove `uv-build` from `requirements-build.txt` since it is no longer needed.

### uv ignores PIP_* environment variables

The pipeline's `cachi2.env` sets `PIP_NO_INDEX` and `PIP_FIND_LINKS` to redirect pip to the prefetched cache. However, [uv does not read `PIP_*` environment variables](https://docs.astral.sh/uv/pip/compatibility/#configuration-files-and-environment-variables) — it has its own equivalents (`UV_FIND_LINKS`, etc.).

If your Dockerfile uses `uv pip install`, pass the prefetch flags explicitly:

```dockerfile
RUN uv pip install --no-index --find-links "${PIP_FIND_LINKS}" \
    -r requirements.txt
```

`PIP_FIND_LINKS` is still set by `cachi2.env` — uv just needs it passed as a CLI argument. This also applies to `uv pip sync` and other `uv pip` subcommands.

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
  --default-index https://console.redhat.com/api/pypi/public-rhai/rhoai/3.5-EA1/cpu-ubi9/simple/ \
  --index-strategy first-index \
  --prerelease=if-necessary \
  --emit-index-url \
  --emit-index-annotation \
  -o requirements.txt
```

If you need a specific RC version, pin it explicitly in your constraints instead of using `--prerelease=allow` globally.

**Diagnosis:** When a multi-arch build fails with `No matching distribution found` for a package with an RC version number, check whether the AIPCC index has that version for all target architectures. Browse the index at `https://console.redhat.com/api/pypi/public-rhai/rhoai/{release}/{variant}/simple/{package}/` and look for wheels with your failing architecture's platform tag (e.g., `linux_s390x`).

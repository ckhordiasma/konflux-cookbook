# Dockerfile Productization for Konflux
> **Scope:** This guide is specific to Red Hat productization, and more specifically to **OpenShift AI (RHOAI)** components being built through Konflux. Other Red Hat products follow similar patterns but may differ in details (base image choices, compliance requirements, etc.). If you're working on a non-RHOAI product, use this as a starting point but verify the specifics with your product's build team.

## What is a Dockerfile.konflux

A `Dockerfile.konflux` is a productized copy of a project's upstream Dockerfile, adapted for Konflux builds. It lives alongside the original Dockerfile in the repo so the upstream build continues to work unchanged. The Konflux pipeline uses `Dockerfile.konflux` (via the `dockerfile` parameter in `.tekton/*.yaml`) to produce the official product image.

The productization work involves swapping upstream base images for Red Hat equivalents, pinning images by digest, hardcoding production values, adding required labels, and restructuring the build to work within Konflux's hermetic build environment. This guide covers these changes.

For hermetic build setup (prefetching dependencies with Hermeto, configuring `hermeto-test.json`, testing with `--network none`), see the [Hermeto Prefetch Guide](hermeto-prefetch.md).

## Starting Point: Copy the Upstream Dockerfile

If a `Dockerfile.konflux` doesn't already exist, start by copying the existing Dockerfile:

```bash
cp Dockerfile Dockerfile.konflux    # or: cp Containerfile Dockerfile.konflux
```

If the repo has a three-layer Dockerfile structure (upstream → midstream → Dockerfile.konflux), derive your Dockerfile.konflux from the **midstream** variant, not the upstream. Common midstream names include `Dockerfile.rhoai`, `Dockerfile.odh`, or product-specific variants. Examples:

- [trainer](https://github.com/red-hat-data-services/trainer/tree/138f5c9d590be0e7aa548798b20ae1b2fa5ac6b9/cmd/trainer-controller-manager): `Dockerfile` → `Dockerfile.odh` → `Dockerfile.rhoai.konflux`
- [rhods-operator](https://github.com/red-hat-data-services/rhods-operator/tree/211330c4d8ad87e36628d6bb0a3edf3394c1c83a/Dockerfiles): `Dockerfile` → `rhoai.Dockerfile` → `Dockerfile.konflux`

The midstream Dockerfile typically already has Red Hat-specific changes (base images, labels, feature flags) that you'd otherwise have to redo.

## Base Image Changes

### Switching to UBI/RHEL Base Images

Upstream Dockerfiles typically use community images (`python:3.12-slim`, `golang:1.22`, `node:20-alpine`). Productized builds must use Red Hat Universal Base Images (UBI) or equivalent RHEL-based images.

Common substitutions:

| Upstream image | Red Hat equivalent | Notes |
|---|---|---|
| `python:3.12-slim` | `registry.access.redhat.com/ubi9/python-312` | Python version in image name |
| `golang:1.22` | `registry.access.redhat.com/ubi9/go-toolset:1.22` | Go toolset includes build deps |
| `node:20` | `registry.access.redhat.com/ubi9/nodejs-20` | |
| `alpine` / `scratch` | `registry.access.redhat.com/ubi9/ubi-minimal` | See [ubi9-micro vs ubi9-minimal](#ubi9-micro-vs-ubi9-minimal) |
| ML/AI workloads | AIPCC base images | Check with AI Platform team for current image names |

When switching base images, you'll also need to adapt the package manager commands:

- `apt-get install` → `microdnf install` or `dnf install`
- `apk add` → `microdnf install` or `dnf install`

UBI images may also have different conventions for user setup, virtual environment paths, and pre-installed packages. Check the image's documentation.

### Base Image Pinning by Digest

All `FROM` lines in `Dockerfile.konflux` must pin to a specific image digest rather than a floating tag. This ensures reproducible builds — the same Dockerfile always produces the same result regardless of when it's built.

```dockerfile
# Bad — floating tag, image content can change without notice
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.4

# Good — pinned to a specific digest
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.4@sha256:a4034741...
```

To find the current digest for an image:

```bash
skopeo inspect docker://registry.access.redhat.com/ubi9/ubi-minimal:9.4 \
  | jq -r '.Digest'
```

**Renovate will keep digests current.** Once you pin by digest, Renovate (configured in the repo) automatically opens PRs to update digests when new image versions are published. It scans `FROM` lines for digest pins and creates update PRs. If you use `ARG BASE_IMAGE=...@sha256:...` + `FROM ${BASE_IMAGE}` instead of a direct `FROM`, you may need renovate config changes to keep automated updates working — check with the build team.

### Removing `--platform` from FROM

Upstream Dockerfiles sometimes include `--platform` flags on `FROM` lines to force a specific architecture during local development or cross-compilation:

```dockerfile
# Upstream — remove this for Konflux
FROM --platform=$BUILDPLATFORM golang:1.22 AS builder
```

Remove `--platform` flags from `FROM` lines in `Dockerfile.konflux`. Konflux multi-platform builds use the [multi-platform-controller](https://github.com/konflux-ci/multi-platform-controller) to provision architecture-native VMs for each target (x86_64, aarch64, ppc64le, s390x), then run `buildah build` natively on each. Since each architecture builds on native hardware, `FROM` lines without `--platform` will naturally pull the correct architecture from a manifest list digest.

The Docker cross-compilation pattern (`FROM --platform=$BUILDPLATFORM` in a builder stage to run build tools at host speed, cross-compiling for `$TARGETPLATFORM`) doesn't apply in Konflux since builds already run natively on the target architecture. Leaving `--platform=$BUILDPLATFORM` in a `FROM` line is harmless (buildah's [imagebuilder library](https://github.com/openshift/imagebuilder/blob/master/dispatchers.go#L40-L49) automatically sets `$BUILDPLATFORM` to the host platform), but it's misleading — the Dockerfile isn't cross-compiling, so removing it makes the intent clearer.

**`TARGETARCH` and `TARGETOS` are available and work correctly.** Buildah automatically sets `TARGETARCH`, `TARGETOS`, `TARGETPLATFORM`, `BUILDARCH`, `BUILDOS`, and `BUILDPLATFORM` to the host platform's values, even without a `--platform` flag. Since Konflux builds run natively on each architecture, `TARGETARCH` resolves to the correct value (e.g., `amd64` on x86_64 VMs, `arm64` on aarch64 VMs). Using `ARG TARGETARCH` in your Dockerfile for arch-specific build logic (like `GOARCH=${TARGETARCH}`) works as expected.

See [data-science-pipelines-operator Dockerfile.konflux](https://github.com/red-hat-data-services/data-science-pipelines-operator/blob/c4e9d9d5198f9f7a4ff0ab00d64bad3293f93e4d/Dockerfile.konflux) for an example.

### ubi9-micro vs ubi9-minimal

Use `ubi9-minimal` if your Dockerfile has any `RUN` instructions. `ubi9-micro` lacks a shell entirely, which breaks the Konflux pipeline's automatic injection of `. /cachi2/cachi2.env &&` before `RUN` commands (this injection uses `sed` to prepend the sourcing command, which requires a shell to execute).

If your image truly needs no `RUN` instructions (a pure `COPY`-based image), `ubi9-micro` is fine and produces smaller images. But this is rare — most production images need at least one `RUN` for permissions, directory creation, or similar setup.

See [models-perf-benchmark-data Dockerfile.konflux](https://github.com/red-hat-data-services/models-perf-benchmark-data/blob/c3fdbfbdb43f923c53c64a580a1be9172faeb9bf/Dockerfile.konflux) for a `ubi9-minimal` example.

### Keep the Final Stage Minimal

Use multi-stage builds to keep the final image lean. Build toolchains (compilers, dev headers, Go toolsets) should live in builder stages, with only the compiled artifacts copied into the final stage. The final stage should use the smallest viable base image — `ubi9-minimal` for most cases, `ubi9-micro` for pure `COPY`-based images.

```dockerfile
# Builder — has all the build tools
FROM registry.access.redhat.com/ubi9/go-toolset:1.22@sha256:abc... AS builder
COPY . /src
RUN go build -o /binary ./cmd/...

# Final — minimal runtime only
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.4@sha256:def...
COPY --from=builder /binary /usr/local/bin/binary
USER 1001
ENTRYPOINT ["/usr/local/bin/binary"]
```

A smaller final image reduces attack surface, speeds up pull times, and makes security scanning faster. Avoid installing build-time-only packages (gcc, make, *-devel) in the final stage — if the runtime needs a shared library, install just the runtime package, not the development headers.

## Build-arg Simplification

Upstream Dockerfiles often use `ARG` to parameterize builds across multiple variants (dev/staging/prod, different Python versions, optional features). For `Dockerfile.konflux`, hardcode the production values directly.

> **Note:** Hardcoding build args is common practice today, but not necessarily ideal. The Konflux pipeline supports a `build-arg-file` parameter that lets you externalize build args into a separate file (e.g., `.build-args`). This keeps the Dockerfile cleaner and puts all variant-specific values in one place. If your project has many args or shares a Dockerfile across products, consider using `build-arg-file` instead of hardcoding. The tradeoff is that Renovate doesn't currently scan argfiles for digest updates — you'd need custom renovate config or manual updates for pinned values in the argfile.

```dockerfile
# Upstream — parameterized for flexibility
ARG PYTHON_VERSION=3.12
ARG INSTALL_DEV_DEPS=false
FROM python:${PYTHON_VERSION}-slim

# Dockerfile.konflux — hardcoded for production
FROM registry.access.redhat.com/ubi9/python-312:1@sha256:abc123...
```

Remove any `ARG` declarations that are no longer needed after hardcoding. Keep args that are genuinely useful for the Konflux build (e.g., `TARGETOS`, `TARGETARCH` if the build uses them).

## FIPS Compliance

To verify that your image passes FIPS checks after making the changes below, see the [check-payload guide](check-payload.md) for running `check-payload` locally.

### FIPS Build Hardcoding

Upstream Dockerfiles may have toggles for FIPS mode (e.g., `ARG FIPS_ENABLED=false`). Productized RHOAI builds need FIPS to be always enabled — remove the toggle and hardcode the FIPS-compliant path.

```dockerfile
# Upstream — conditional FIPS
ARG FIPS_ENABLED=false
RUN if [ "$FIPS_ENABLED" = "true" ]; then \
      <fips setup>; \
    fi

# Dockerfile.konflux — FIPS is always on, just run the setup
RUN <fips setup>
```

See [data-science-pipelines-operator Dockerfile](https://github.com/red-hat-data-services/data-science-pipelines-operator/blob/c4e9d9d5198f9f7a4ff0ab00d64bad3293f93e4d/Dockerfile) vs [Dockerfile.konflux](https://github.com/red-hat-data-services/data-science-pipelines-operator/blob/c4e9d9d5198f9f7a4ff0ab00d64bad3293f93e4d/Dockerfile.konflux) for a before/after.

### Go FIPS Builds

Go binaries in FIPS-compliant images must be built with the BoringCrypto-backed crypto libraries. The required flags:

```dockerfile
ENV GOEXPERIMENT=strictfipsruntime
RUN CGO_ENABLED=1 go build -tags strictfipsruntime -o /binary ./cmd/...
```

All three pieces are required:
- `GOEXPERIMENT=strictfipsruntime` — tells the Go runtime to use the FIPS-validated crypto implementation
- `-tags strictfipsruntime` — includes FIPS-specific source files at compile time
- `CGO_ENABLED=1` — BoringCrypto requires cgo; static-only builds won't link to the FIPS module

See [ogx-k8s-operator Dockerfile](https://github.com/red-hat-data-services/ogx-k8s-operator/blob/bf732614a7e78c5477422d137360d2f1b3a895cf/Dockerfile) for the full pattern, and [odh-cli Dockerfile.konflux](https://github.com/red-hat-data-services/odh-cli/blob/f4e654f16c63300a9ba5e197e953aae26b41635c/Dockerfile.konflux) for applying it to submodule builds.

## Eliminating Network Downloads

Any `curl`, `wget`, `git clone`, or similar download in the Dockerfile must be replaced. Hermetic builds have no network access, and even before hermeticization, direct downloads are problematic for reproducibility and SBOM completeness.

For the full list of replacement strategies (ranked from most to least preferred), see the [Read the Dockerfile.konflux](hermeto-prefetch.md#read-the-dockerfilekonfux) section of the Hermeto Prefetch Guide. The short version: prefer choosing a base image that already has the tool, or use multi-stage `COPY --from=` from a trusted Red Hat image, or build from source via a git submodule. The generic fetcher is a last resort and requires a policy exception.

## Removing Unnecessary Package Installs

Before adding RPM prefetch entries (`rpms.in.yaml`) for a system package, check whether the package is actually needed in the Konflux build. Some packages in the upstream or midstream Dockerfile are only needed for development, testing, or features that aren't active in the productized build.

For example, [trainer's Dockerfile.odh](https://github.com/red-hat-data-services/trainer/blob/138f5c9d590be0e7aa548798b20ae1b2fa5ac6b9/cmd/trainer-controller-manager/Dockerfile.odh) installs `bind-utils`, but the Dockerfile.konflux drops it entirely rather than adding it to RPM prefetch. Each additional RPM adds build time, image size, and potential security surface.

Review each package and ask: does the final image or build process actually use this? If not, leave it out. Removing unnecessary packages also helps with FIPS compliance — fewer packages means fewer binaries that need to pass `check-payload` validation, and fewer chances of shipping a non-FIPS-compliant crypto library.

## Dockerfile Placement and Naming

### Multi-component Repos

When a repo produces multiple container images and all Dockerfiles live at the repo root, use a component-suffix naming convention to distinguish them:

```
Dockerfile.konflux.autogluon
Dockerfile.konflux.huggingface
Dockerfile.konflux.lightgbm
```

Each file maps to a separate component in Konflux, with its own PipelineRun in `.tekton/`. This naming convention is a practical necessity when all Dockerfiles are at the top level — if your repo structure places each component in its own subdirectory, you can instead use `Dockerfile.konflux` in each subdirectory (see [Subdirectory Build Contexts](#subdirectory-build-contexts) below).

See [kserve-autogluon-server](https://github.com/red-hat-data-services/kserve-autogluon-server/blob/2f5b94d0717294d7e2b7813165bf1fe913168c61/Dockerfile.konflux.autogluon) for the suffix-naming example.

### Subdirectory Build Contexts

When the build context is a subdirectory of the repo, one common pattern is to place `Dockerfile.konflux` at the **repo root** and use the `path-context` and `dockerfile` parameters in the PipelineRun to wire it up:

```yaml
# In .tekton/my-component-push.yaml
params:
  - name: path-context
    value: python
  - name: dockerfile
    value: ../Dockerfile.konflux.autogluon
```

The `path-context` sets the Docker build context directory. The `dockerfile` path is relative to that context, so `../Dockerfile.konflux.autogluon` reaches back to the repo root. This keeps all Konflux Dockerfiles in a predictable location regardless of where the build context lives. The alternative — placing the Dockerfile inside the subdirectory and adjusting `dockerfile` to be a simple filename — also works and may be more natural for repos where each subdirectory is self-contained. Choose whichever convention the repo already follows.

See [kserve-autogluon-server](https://github.com/red-hat-data-services/kserve-autogluon-server/blob/2f5b94d0717294d7e2b7813165bf1fe913168c61/Dockerfile.konflux.autogluon) with `path-context: python` and `dockerfile: ../Dockerfile.konflux.autogluon`.

## Container Labels

Konflux and Red Hat build systems expect specific labels on the produced images. At minimum, add these to your `Dockerfile.konflux`:

```dockerfile
LABEL com.redhat.component="your-component-name" \
      name="your-product/your-component" \
      version="x.y" \
      summary="One-line summary" \
      description="Longer description of what this image provides" \
      io.k8s.display-name="Display Name" \
      io.k8s.description="Description for OpenShift" \
      io.openshift.tags="tag1,tag2"
```

Check your product's label requirements — some products have additional required labels for compliance or catalog metadata.

## Python-specific Notes

### `--no-build-isolation` for Local Package Installs

When running `pip install .` to install a local package from source in a hermetic build, add `--no-build-isolation`:

```dockerfile
RUN pip install --no-build-isolation .
```

This prevents pip from creating an isolated build environment and downloading build dependencies from the network. In a hermetic build, pip's build isolation would fail because it can't reach PyPI. With `--no-build-isolation`, pip uses whatever build backends are already available in the environment (or in the prefetched cache).

This is commonly used as a defensive practice in hermetic builds, though it's not strictly required when build backends (like `setuptools`, `wheel`) are already present in the prefetched dependencies.

See [kserve-autogluon-server Dockerfile.konflux.autogluon](https://github.com/red-hat-data-services/kserve-autogluon-server/blob/2f5b94d0717294d7e2b7813165bf1fe913168c61/Dockerfile.konflux.autogluon) for an example.

## Git Submodule Builds

When you need a tool that isn't available as an RPM or in a trusted image, you can add its source code as a git submodule and build it from source in a builder stage. This keeps the build hermetic and gives you full control over the build.

```dockerfile
# Builder stage for yq
FROM registry.access.redhat.com/ubi9/go-toolset:1.22@sha256:abc... AS yq-builder
COPY .git/modules/yq /src/yq
WORKDIR /src/yq
ENV GOEXPERIMENT=strictfipsruntime
RUN CGO_ENABLED=1 go build -tags strictfipsruntime -o /yq .

# Final stage
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.4@sha256:def...
COPY --from=yq-builder /yq /usr/local/bin/yq
```

The submodule's dependencies are prefetched along with the main project's dependencies via the hermeto config. See [odh-cli Dockerfile.konflux](https://github.com/red-hat-data-services/odh-cli/blob/f4e654f16c63300a9ba5e197e953aae26b41635c/Dockerfile.konflux) for the full pattern.

## Multi-Architecture Builds

RHOAI components typically target x86_64 and aarch64 initially, with ppc64le and s390x added later. Your local machine covers one architecture — for the others, use the [Beaker VM guide](beaker-vm.md) to provision test VMs on different CPU architectures.

Key multi-arch concerns when productizing a Dockerfile:

- **`--platform` on `FROM` lines** — Konflux builds natively on each architecture, so cross-compilation flags like `--platform=$BUILDPLATFORM` are not needed but won't break the build (see [details above](#removing---platform-from-from))
- **Package availability varies by architecture** — check that any `microdnf install` packages are available on all targets. Some packages in the standard UBI repos are not available on ppc64le or s390x.
- **Python packages may lack wheels for some architectures** — ppc64le and s390x commonly lack pre-built wheels. See the [hermeto Python guide](hermeto-python.md) for using AIPCC wheels or building from source on those architectures.

Once your Dockerfile.konflux is productized, the [hermeto guide's remote testing section](hermeto-prefetch.md#testing-on-remote-architectures) covers syncing your project to a remote host and running the full hermetic build there.

## Checklist

Use this as a quick reference when creating or reviewing a `Dockerfile.konflux`:

- [ ] Base images switched to UBI/RHEL equivalents
- [ ] All `FROM` lines pinned by digest
- [ ] `--platform` flags removed from `FROM` lines
- [ ] `apt-get`/`apk` replaced with `microdnf`/`dnf`
- [ ] Build args hardcoded to production values (FIPS enabled, no dev toggles)
- [ ] Go builds use FIPS flags (`GOEXPERIMENT=strictfipsruntime`, `-tags strictfipsruntime`, `CGO_ENABLED=1`)
- [ ] No `curl`/`wget`/`git clone` downloads — replaced with `COPY --from=`, base image choice, or submodule builds
- [ ] Unnecessary package installs removed rather than added to RPM prefetch
- [ ] Required container labels added
- [ ] `ubi9-minimal` used instead of `ubi9-micro` if any `RUN` instructions exist
- [ ] Dockerfile placed and named correctly for the repo structure
- [ ] `. /cachi2/cachi2.env` is NOT committed in the Dockerfile (pipeline injects it automatically)

## What's Next

- **Set up hermetic builds** — prefetch dependencies so your build works offline. See [hermeto-prefetch](hermeto-prefetch.md).
- **Verify FIPS compliance** — run check-payload locally to catch issues before they block a release. See [check-payload](check-payload.md).
- **Deploy to Konflux** — get your productized Dockerfile into actual Konflux pipelines. See [deploying-to-konflux](deploying-to-konflux.md).

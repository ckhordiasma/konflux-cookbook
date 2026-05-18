# Running check-payload Locally for FIPS Compliance

> **Scope:** This guide covers running [check-payload](https://github.com/openshift/check-payload) locally to detect FIPS compliance issues in container images before pushing to Konflux. It targets RHOAI developers on macOS (Apple Silicon or x86) and Linux workstations with podman installed.

## What check-payload Does

`check-payload` scans ELF executables inside container images and validates them for FIPS compliance. It checks that:

- Go binaries are built with `CGO_ENABLED=1`, `GOEXPERIMENT=strictfipsruntime`, and `-tags strictfipsruntime`
- All executables are dynamically linked to the system's FIPS-certified OpenSSL (`libcrypto.so`)
- The base OS is a FIPS-certified RHEL distribution
- The required FIPS-certified cryptographic artifacts (e.g., `openssl-fips-provider` RPM) are present at the right version

Running it locally catches these issues before they surface in the Konflux release pipeline, where FIPS failures block releases.

## Prerequisites

- **podman** installed and running (`podman machine start` on macOS)
- **An image to scan** — either a registry URI (e.g., `quay.io/your-org/your-image@sha256:...`) or a locally built image

## Quick Start: Scan an Image

check-payload needs a Linux environment with `podman` and `nm` (from binutils) to inspect ELF executables. On macOS, podman runs containers inside a Linux VM, so the simplest approach is to run the entire scan inside a container.

The check-payload container image (built from [Dockerfile.upstream](https://github.com/openshift/check-payload/blob/main/Dockerfile.upstream)) includes all required tools: check-payload itself plus `skopeo` and `umoci` for pulling and unpacking images.

### 1. Build the check-payload container (one-time setup)

```bash
git clone https://github.com/openshift/check-payload.git
cd check-payload
podman build --platform linux/amd64 -f Dockerfile.upstream -t check-payload:local .
```

`--platform linux/amd64` ensures the build downloads the correct x86_64 tooling bundled in the Dockerfile (oc, opm, umoci), regardless of your host architecture. This takes a few minutes the first time.

### 2. Scan an image from a registry

```bash
podman run --platform linux/amd64 --rm --entrypoint bash \
  check-payload:local -c "
    skopeo copy --remove-signatures \
      docker://quay.io/your-org/your-image@sha256:abc123 \
      oci:/tmp/image:scan &&
    umoci unpack --image /tmp/image:scan /tmp/unpacked &&
    /check-payload scan local --path /tmp/unpacked/rootfs
  "
```

This pulls the image with `skopeo`, unpacks it with `umoci`, and scans the resulting rootfs — all inside one container. No podman-in-podman, no `--privileged`, no VM SSH.

**Notes:**
- `--remove-signatures` is required because OCI layout doesn't support signatures
- The `oci:/tmp/image:scan` format requires a tag after the colon (here `scan` — the name is arbitrary)
- For digest references, use the `@sha256:...` format without a tag: `docker://registry/image@sha256:abc123`
- For tag references, use the tag directly: `docker://registry/image:v1.0`
- Don't combine both tag and digest (`image:v1.0@sha256:...`) — skopeo doesn't support that

If the registry requires authentication, mount your pull secret into the container:

```bash
podman run --platform linux/amd64 --rm --entrypoint bash \
  -v "${XDG_RUNTIME_DIR}/containers/auth.json:/run/containers/0/auth.json:ro" \
  check-payload:local -c "
    skopeo copy --remove-signatures \
      docker://quay.io/your-org/your-image@sha256:abc123 \
      oci:/tmp/image:scan &&
    umoci unpack --image /tmp/image:scan /tmp/unpacked &&
    /check-payload scan local --path /tmp/unpacked/rootfs
  "
```

### 3. Read the results

**Passing** — exit code 0:
```
---- Successful run
```

**Passing with warnings** — exit code 0 (warnings are informational, not blocking):
```
---- Warning Report
[table of warnings]
---- Successful run with warnings
```

**Failing** — exit code 1:
```
---- Failure Report
+----------------+----------+----------+----------------------------------------------+------------------------------------------+-------+
| OPERATOR NAME  | TAG NAME | RPM NAME | EXECUTABLE NAME                              | STATUS                                   | IMAGE |
+----------------+----------+----------+----------------------------------------------+------------------------------------------+-------+
|                |          |          | /usr/local/bin/myapp                         | go binary is not CGO_ENABLED             |       |
|                |          |          | /usr/local/bin/myapp                         | go binary does not enable GOEXPERIMENT=strictfipsruntime |       |
+----------------+----------+----------+----------------------------------------------+------------------------------------------+-------+
```

## Common FIPS Errors and Fixes

### Go binary errors

These are the most common FIPS failures for RHOAI components.

| Error | Meaning | Fix |
|---|---|---|
| `go binary is not CGO_ENABLED` | Binary was built without cgo | Add `CGO_ENABLED=1` to the build command |
| `go binary does not enable GOEXPERIMENT=strictfipsruntime` | Missing GOEXPERIMENT env var | Add `ENV GOEXPERIMENT=strictfipsruntime` before the `go build` |
| `go binary does not contain required tag(s)` | Missing strictfipsruntime build tag | Add `-tags strictfipsruntime` to `go build` flags |
| `go binary has no build tags set` | No build tags at all (warning) | Add `-tags strictfipsruntime` |
| `go binary has invalid build tag(s) set` | Has `no_openssl` or similar bad tag | Remove the `no_openssl` tag from build flags |
| `x_cgo_init or _cgo_topofstack not found` | CGO was nominally enabled but cgo bootstrap symbols are missing | Ensure a C compiler is available in the build image and `CGO_ENABLED=1` is actually set |
| `go binary does not contain required symbol(s)` | Missing golang-fips/openssl vendor symbols | Ensure you're using a Go toolchain that includes the FIPS shim (the UBI `go-toolset` images include this) |

#### Fixing a Go binary

All three pieces are required in your `Dockerfile.konflux`:

```dockerfile
ENV GOEXPERIMENT=strictfipsruntime
RUN CGO_ENABLED=1 go build -tags strictfipsruntime -o /binary ./cmd/...
```

If building multiple binaries or submodules, apply these flags to every `go build` invocation. See the [Go FIPS Builds](dockerfile-productization.md#go-fips-builds) section in the Dockerfile Productization guide for examples.

### OpenSSL / libcrypto errors

| Error | Meaning | Fix |
|---|---|---|
| `did not find libcrypto library within binary` | Executable doesn't link to libcrypto | Ensure the binary is dynamically linked (not statically compiled) to system OpenSSL |
| `could not find dependent openssl version within container image` | The libcrypto `.so` that the binary expects isn't in the image | Install `openssl-libs` in the final image, or verify the base image includes it |
| `found multiple different libcrypto versions` | Multiple OpenSSL versions detected | Remove duplicate OpenSSL installations; use only the system-provided one |

### OS / distribution errors

| Error | Meaning | Fix |
|---|---|---|
| `operating system is not FIPS certified` | Base image uses a non-certified RHEL version | Use a FIPS-certified base: RHEL 8.4–8.10, 9.0, 9.2, 9.4–9.8 |
| `could not find distribution file` | No `/etc/redhat-release` file found | Use a UBI/RHEL base image, not Alpine or Debian |
| `required FIPS certified artifact not found` | The `openssl-fips-provider` or `openssl-libs` RPM is missing | Ensure the base image includes the OpenSSL FIPS provider; don't strip it in your Dockerfile |
| `FIPS certified artifact version below required minimum` | OpenSSL version too old | Update your base image to a newer UBI version |

### Static linking errors

| Error | Meaning | Fix |
|---|---|---|
| `executable is not dynamically linked` | A binary is statically linked | Rebuild with dynamic linking. For Go, use `CGO_ENABLED=1`. For C/C++, don't pass `-static` |

Static linking is a FIPS violation because statically linked binaries can't use the system's FIPS-validated OpenSSL module at runtime. Exceptions exist for binaries that genuinely don't perform cryptography (e.g., `tini-static`, `ldconfig`). If a static binary legitimately doesn't use crypto, you can add it to a check-payload config exception — see [Suppressing Known False Positives](#suppressing-known-false-positives).

## FIPS Build Hardcoding in Dockerfile.konflux

Upstream Dockerfiles often have toggles for FIPS mode. For `Dockerfile.konflux`, always hardcode the FIPS-enabled path:

```dockerfile
# Upstream — conditional FIPS
ARG FIPS_ENABLED=false
RUN if [ "$FIPS_ENABLED" = "true" ]; then \
      <fips setup>; \
    fi

# Dockerfile.konflux — FIPS is always on
RUN <fips setup>
```

Remove `ARG FIPS_ENABLED` entirely. See [FIPS Build Hardcoding](dockerfile-productization.md#fips-build-hardcoding) in the Dockerfile Productization guide.

## Python / OpenSSL Considerations

Python images built on UBI base images generally pass FIPS checks without special configuration because:

- The Python interpreter in UBI images is dynamically linked to the system OpenSSL
- The system OpenSSL in RHEL/UBI is FIPS-certified

Issues can arise when:

- **A non-UBI base image is used** — Alpine and Debian ship non-FIPS-certified OpenSSL builds. Always use UBI-based Python images (`ubi9/python-3XX`) for Konflux builds.
- **A pip package vendors its own OpenSSL** — Packages like `cryptography` can ship a bundled `libcrypto.so` that may not be FIPS-certified. On UBI images with system OpenSSL available, pip packages typically use the system library, but verify by checking `ldd` on the installed `.so` files.
- **Python is built from source without system OpenSSL** — If the Dockerfile compiles Python from source, ensure it links to the system OpenSSL (`--with-openssl=/usr` or similar), not a vendored copy.

For most RHOAI Python images, using the standard UBI Python base image and installing dependencies with pip is sufficient. check-payload validates the ELF-level linkage, not Python's runtime crypto configuration.

## Handling False Positives

Some binaries legitimately don't use cryptography but fail check-payload because they're statically linked (e.g., `pandoc`, `py-spy`, `tini-static`). While check-payload supports custom `config.toml` files for local use, this does not help with the release pipeline.

> **RHOAI note:** The Konflux build and release pipeline runs check-payload with its built-in configuration — there is no way to pass a custom `config.toml`. Any component that fails check-payload will block the RHOAI operator release until the failure is resolved through a formal exception. The RHOAI DevOps team has also implemented a build-time FIPS check on downstream CI builds, to allow for these issues to be caught earlier.

If a binary in your image meets **both** of these conditions:

1. It is necessary for the runtime of the image (can't be removed)
2. It performs no cryptographic operations

Then submit a PR to [openshift/check-payload](https://github.com/openshift/check-payload) to add an exception to the global `config.toml`. Use the `--print-exceptions` (`-p`) flag to generate the exact TOML syntax for your PR:

```bash
./scripts/check-payload.sh -i quay.io/your-org/your-image@sha256:abc123 --print-exceptions
```

This prints TOML blocks like:

```toml
[[payload.my-component.ignore]]
error = "ErrNotDynLinked"
files = ["/usr/local/bin/pandoc"]
```

Include this in your PR to [config.toml](https://github.com/openshift/check-payload/blob/main/config.toml), with a comment explaining why the binary is safe to exclude and a Jira ticket tracking the exception. See the existing RHOAI exceptions in that file (tracked under RHOAIENG-58626) for the expected format.

If the binary is **not** necessary for the image, the better fix is to remove it from the Dockerfile entirely — fewer binaries means fewer FIPS findings to deal with.

## Useful Flags

| Flag | Description |
|---|---|
| `--verbose` | Include detailed output and success report |
| `--output-format markdown` | Output as Markdown table (also: `csv`, `html`, `table`) |
| `--output-file report.txt` | Write report to a file |
| `-p, --print-exceptions` | Print TOML exception rules for failures |
| `--parallelism N` | Concurrent scan workers (default: 5) |
| `--filter-files path1,path2` | Skip specific files |
| `--filter-dirs dir1,dir2` | Skip specific directories |

## Checklist

Before pushing an image to Konflux, verify:

- [ ] Go binaries built with `CGO_ENABLED=1`, `GOEXPERIMENT=strictfipsruntime`, and `-tags strictfipsruntime`
- [ ] FIPS toggles (`ARG FIPS_ENABLED`) removed — FIPS path hardcoded
- [ ] Base image is a FIPS-certified RHEL/UBI version
- [ ] No statically linked binaries that perform cryptography
- [ ] `check-payload scan local` passes (exit code 0)

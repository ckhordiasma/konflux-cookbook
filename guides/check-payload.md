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

### 1. Build the check-payload container image (one-time setup)

```bash
git clone https://github.com/openshift/check-payload.git
cd check-payload
podman build --platform linux/amd64 -f Dockerfile.upstream -t check-payload:local .
```

Use `--platform linux/amd64` to ensure the build downloads the correct x86_64 tooling bundled in the Dockerfile, regardless of your host architecture. This takes a few minutes the first time.

### 2. Scan an image from a registry

```bash
podman run --platform linux/amd64 --privileged \
  check-payload:local scan image \
  --spec quay.io/your-org/your-image@sha256:abc123...
```

The `--privileged` flag is required because check-payload uses `podman image mount` internally to access the container filesystem. The inner podman pulls the image from the registry, mounts it, walks the filesystem for ELF executables, and runs them through the FIPS validation engine.

If the registry requires authentication, pass your pull secret:

```bash
podman run --platform linux/amd64 --privileged \
  -v "${XDG_RUNTIME_DIR}/containers/auth.json:/run/containers/0/auth.json:ro" \
  check-payload:local scan image \
  --spec quay.io/your-org/your-image@sha256:abc123...
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

## Scanning a Locally Built Image

If you've built an image locally and want to scan it before pushing to a registry:

1. **Push to your personal namespace** and then scan from the registry:

    ```bash
    podman build -t quay.io/your-user/my-image:fips-test -f Dockerfile.konflux .
    podman push quay.io/your-user/my-image:fips-test
    podman run --platform linux/amd64 --privileged \
      check-payload:local scan image \
      --spec quay.io/your-user/my-image:fips-test
    ```

2. **Or** scan directly from local podman storage by tagging the image and scanning inside the podman machine VM — see [Running Inside the Podman Machine VM](#running-inside-the-podman-machine-vm) below.

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

## Suppressing Known False Positives

Some binaries legitimately don't use cryptography but fail check-payload because they're statically linked (e.g., `pandoc`, `py-spy`, `tini-static`). Use `--print-exceptions` (`-p`) to generate TOML exception rules:

```bash
podman run --platform linux/amd64 --privileged \
  check-payload:local scan image \
  --spec quay.io/your-org/your-image@sha256:abc123 \
  --print-exceptions
```

This prints TOML blocks like:

```toml
[[payload.my-component.ignore]]
error = "ErrNotDynLinked"
files = ["/usr/local/bin/pandoc"]
```

You can add these to a custom `config.toml` and pass it with `--config`:

```bash
podman run --platform linux/amd64 --privileged \
  -v ./my-config.toml:/config.toml:ro \
  check-payload:local scan image \
  --spec quay.io/your-org/your-image@sha256:abc123 \
  --config /config.toml
```

The default config already includes exceptions for known RHOAI images (workbench pandoc, py-spy, etc.) tracked under RHOAIENG-58626.

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

## Running Inside the Podman Machine VM

On macOS, you can also SSH into the podman machine VM to run check-payload directly. This avoids the podman-in-podman overhead and lets you scan locally built images from podman's storage:

```bash
# Build your image (runs in the VM via podman)
podman build -t my-image:test -f Dockerfile.konflux .

# SSH into the VM
podman machine ssh

# Inside the VM: install dependencies and build check-payload
sudo dnf install -y git golang binutils
git clone https://github.com/openshift/check-payload.git
cd check-payload
make

# Scan the locally built image
sudo ./check-payload scan image --spec localhost/my-image:test
```

This is a heavier setup but useful when you need to scan images that aren't in a registry.

## Checklist

Before pushing an image to Konflux, verify:

- [ ] Go binaries built with `CGO_ENABLED=1`, `GOEXPERIMENT=strictfipsruntime`, and `-tags strictfipsruntime`
- [ ] FIPS toggles (`ARG FIPS_ENABLED`) removed — FIPS path hardcoded
- [ ] Base image is a FIPS-certified RHEL/UBI version
- [ ] No statically linked binaries that perform cryptography
- [ ] `check-payload scan image` passes (exit code 0)

---
name: hermeto-prefetch
description: Set up Hermeto prefetching for hermetic Konflux builds
version: 1.0.0
---

# Set Up Hermeto Prefetching

Read the reference doc at `guides/hermeto-prefetch.md` (relative to the plugin root) for the full procedure. Follow the steps below using that doc as your guide.

## Steps

1. **Ask about package managers**: Ask the user what package managers their project uses (pip, cargo, npm, etc.) and whether they need RPM prefetching for system packages.

2. **Identify requirements and lockfiles**: Look for existing requirements files, lockfiles, or `pyproject.toml` in the project. For pip projects, check if there are `.in` files that need compilation or only pre-resolved `.txt` files.

3. **Determine target Python version**: Read the project's Dockerfile to identify the base image and Python version. This version must match the `--python-version` flag used during requirements compilation.

4. **Generate `hermeto.json`**: Create the hermeto config file listing all package managers and their requirements files. If the project uses pip with multiple requirements files, list them all. Enable binary wheels with multi-arch support if the project has packages with native extensions (Rust, C).

5. **Generate `rpms.in.yaml`** (if needed): If the Dockerfile installs system packages with `microdnf` or `dnf`, create `rpms.in.yaml` listing those packages and all target architectures. Set the `context.containerfile` to point at the Dockerfile and the correct build stage.

6. **Copy and configure Makefiles**: Copy `scripts/Makefile.hermeto-config` and `scripts/Makefile.hermeto-build` from the cookbook into the project. Set the configuration variables (`PYTHON_VERSION`, `REQUIREMENTS_IN`, `BINARY_ARCH`, `DOCKERFILE`, `BUILD_CONTEXT`) to match the project layout.

7. **Run the Makefile stages**: Walk through the stages to verify the hermetic build works:
   - `make -f Makefile.hermeto-config pip-compile` -- compile requirements
   - `make -f Makefile.hermeto-config build-deps` -- find build backends (skip if using binary wheels)
   - `make -f Makefile.hermeto-config rpm-lock` -- resolve RPMs (skip if no rpms.in.yaml)
   - `make -f Makefile.hermeto-config hermeto-config` -- generate hermeto.json
   - `make -f Makefile.hermeto-build prefetch` -- prefetch everything
   - `make -f Makefile.hermeto-build dockerfile` -- generate hermetic Dockerfile
   - `make -f Makefile.hermeto-build build` -- run the offline build

8. **Summarize**: Report what was created and next steps:
   - Files to commit: `hermeto.json`, `rpms.in.yaml`, `rpms.lock.yaml`, `Makefile.hermeto-config`, `Makefile.hermeto-build`, compiled requirements files
   - Files to gitignore: `.hermeto/`, `.hermeto.env`
   - Remind the user to set up the Konflux PR pipeline with hermeto prefetch tasks if not already done

---
name: check-payload
description: Run check-payload locally to scan container images for FIPS compliance issues before they block a Konflux release
version: 1.0.0
---

# Run check-payload for FIPS Compliance

Read `guides/check-payload.md` (relative to the plugin root) thoroughly before starting. It is the source of truth for all check-payload details — do not duplicate its content, reference it as you go.

## Steps

1. **Check prerequisites**: Ask the user what platform they're on (macOS vs Linux) — macOS runs the scan under QEMU emulation, which is slower. Confirm podman is installed and running. Ask whether they've already built the check-payload container image — if not, walk them through the one-time setup from the guide.

2. **Determine what to scan**: Ask the user whether they want to scan:
   - A registry image (they'll need the full image reference with tag or digest)
   - A locally built image (they'll need the local image name/tag)
   
   If they're unsure which image to scan, help them identify the right one — ask what component they're working on and whether they have a recent build.

3. **Run the scan**: Follow the manual podman commands in the guide (skopeo copy, umoci unpack, check-payload scan). Let the user know the scan may take a minute. If the image requires registry authentication, help them mount their pull secret.

4. **Interpret results**: 
   - If the scan passes (exit code 0), confirm and move on.
   - If it fails, walk through each failure using the "Common FIPS Errors and Fixes" section in the guide. For Go binary errors, point to the specific build flags needed. For OpenSSL/OS errors, identify what needs to change in the base image or Dockerfile.

5. **Handle false positives**: If any failures look like false positives (e.g., statically linked binaries that don't do crypto), explain the exception process from the guide. Offer to generate the TOML exception syntax with `--print-exceptions` and help draft the check-payload PR.

6. **Next steps**: Based on what was found, point the user to relevant guides and skills — dockerfile-productization for build flag changes, hermeto-prefetch for hermetic build setup, or conforma for broader release policy validation.

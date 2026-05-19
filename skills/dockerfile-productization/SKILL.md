---
name: dockerfile-productization
description: Productize an upstream Dockerfile for Konflux builds — base image swaps, digest pinning, FIPS compliance, label metadata, and build-arg simplification
version: 1.0.0
---

# Productize a Dockerfile for Konflux

Read `guides/dockerfile-productization.md` (relative to the plugin root) thoroughly before starting. It is the source of truth for all Dockerfile productization details — do not duplicate its content, reference it as you go.

## Steps

1. **Identify the Dockerfile**: Ask the user which Dockerfile to productize. Determine whether a `Dockerfile.konflux` already exists — if so, ask whether to review/update it or start fresh. If the repo has a midstream variant (Dockerfile.odh, Dockerfile.rhoai), confirm whether to derive from that rather than the upstream Dockerfile. For multi-component repos, ask about the repo structure — whether components live in subdirectories or share the root — to determine the right naming convention (e.g., `Dockerfile.konflux.component` vs per-directory `Dockerfile.konflux`).

2. **Analyze the upstream Dockerfile**: Read the source Dockerfile and categorize each element that needs to change:
   - Base images that need UBI/RHEL equivalents
   - Tags that need digest pinning
   - `--platform` flags on FROM lines
   - Package manager commands (apt-get/apk → microdnf/dnf)
   - Build args that should be hardcoded
   - FIPS toggles that need hardcoding
   - Network downloads (curl/wget/git clone) that need replacement
   - Missing container labels

   Present this summary to the user before making changes.

3. **Apply changes incrementally**: Work through the changes one category at a time, showing the user each change and asking for input. Follow the guide's recommendations for each category. For base image swaps, help look up current digests with `skopeo inspect`.

4. **FIPS compliance**: If the project has Go binaries, ensure the FIPS build flags are set correctly (`GOEXPERIMENT`, `-tags strictfipsruntime`, `CGO_ENABLED=1`). Suggest running check-payload after the Dockerfile is ready.

5. **Review against checklist**: Walk through the checklist at the end of the guide to confirm nothing was missed. Present any remaining items to the user.

6. **Next steps**: Based on the Dockerfile, point the user to relevant guides and skills — hermeto-prefetch for hermetic build setup, check-payload for FIPS validation, or deploying-to-konflux for getting it into pipelines.

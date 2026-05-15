# Guides TODO



## Hermetic Builds — Open Questions


## Dockerfile.konflux Productization best practices 

- [ ] Guide on creating a Dockerfile.konflux from an upstream Dockerfile
  - Switching upstream base images to UBI/RHEL equivalents (e.g., `python:3.12-slim` → `ubi9/python-312`, or AIPCC base images for ML workloads), including swapping `apt-get` → `microdnf`/`dnf` and adapting user/venv conventions
  - Base image pinning by digest
  - Build-arg simplification (hardcoding variant-specific values)
  - Label changes
  - Removing `--platform` from FROM (see [data-science-pipelines-operator Dockerfile.konflux](https://github.com/red-hat-data-services/data-science-pipelines-operator/blob/rhoai-3.5-ea.1/Dockerfile.konflux))
  - FIPS build hardcoding — removing dev toggles like `FIPS_ENABLED` (see [data-science-pipelines-operator Dockerfile](https://github.com/red-hat-data-services/data-science-pipelines-operator/blob/rhoai-3.5-ea.1/Dockerfile) vs [Dockerfile.konflux](https://github.com/red-hat-data-services/data-science-pipelines-operator/blob/rhoai-3.5-ea.1/Dockerfile.konflux))
  - Dockerfile placement when build context is a subdirectory — place Dockerfile.konflux at repo root, use `path-context` + relative `dockerfile` in pipeline (see [kserve-autogluon-server](https://github.com/red-hat-data-services/kserve-autogluon-server/blob/rhoai-3.5-ea.1/Dockerfile.konflux.autogluon) with `path-context: python` and `dockerfile: ../Dockerfile.konflux.autogluon`)
  - Component-suffix naming for multi-component repos (`Dockerfile.konflux.autogluon`, `Dockerfile.konflux.huggingface`, etc.)
  - `--no-build-isolation` for `pip install .` of local packages — commonly used in hermetic builds as a defensive practice, though not strictly required when build backends are in the prefetched cache (see [kserve-autogluon-server Dockerfile.konflux.autogluon](https://github.com/red-hat-data-services/kserve-autogluon-server/blob/rhoai-3.5-ea.1/Dockerfile.konflux.autogluon))
  - `ubi9-micro` vs `ubi9-minimal` — `ubi9-micro` lacks a shell, which breaks the pipeline's `RUN` injection of `. /cachi2/cachi2.env &&`. Use `ubi9-minimal` if your Dockerfile has any `RUN` instructions (see [models-perf-benchmark-data](https://github.com/red-hat-data-services/models-perf-benchmark-data/blob/rhoai-3.5-ea.1/Dockerfile.konflux))
  - FIPS compliance for Go builds — `GOEXPERIMENT=strictfipsruntime`, `-tags strictfipsruntime`, `CGO_ENABLED=1` (see [ogx-k8s-operator upstream Dockerfile](https://github.com/red-hat-data-services/ogx-k8s-operator/blob/rhoai-3.5-ea.1/Dockerfile) for the full pattern, and [odh-cli yq-builder stage](https://github.com/red-hat-data-services/odh-cli/blob/rhoai-3.5-ea.1/Dockerfile.konflux) for applying it to submodule builds)
  - Eliminating `curl`/`wget` downloads — multi-stage `COPY --from=` from trusted images (see [must-gather](https://github.com/red-hat-data-services/must-gather/blob/rhoai-3.5-ea.1/Dockerfile.konflux): kubectl from `ose-cli-rhel9`), or choosing a base image that already includes the tools (see [odh-cli](https://github.com/red-hat-data-services/odh-cli/blob/rhoai-3.5-ea.1/Dockerfile.konflux): `ose-cli-rhel9` base for kubectl/oc)
  - Git submodule builds — adding a tool's source as a git submodule and building from source in a builder stage (see [odh-cli yq-builder](https://github.com/red-hat-data-services/odh-cli/blob/rhoai-3.5-ea.1/Dockerfile.konflux))
  - Three-layer Dockerfile pattern (upstream → midstream → Dockerfile.konflux) — repos with both an upstream `Dockerfile` and a midstream variant (`Dockerfile.rhoai`, `Dockerfile.odh`) derive Dockerfile.konflux from the midstream, not upstream (see [trainer](https://github.com/red-hat-data-services/trainer/tree/rhoai-3.5-ea.1/cmd/trainer-controller-manager): `Dockerfile` → `Dockerfile.odh` → `Dockerfile.rhoai.konflux`, and [rhods-operator](https://github.com/red-hat-data-services/rhods-operator/tree/rhoai-3.5-ea.1/Dockerfiles): `Dockerfile` → `rhoai.Dockerfile` → `Dockerfile.konflux`)
  - Removing unnecessary package installs — before adding RPM prefetch (`rpms.in.yaml`) for a system package, check whether it is actually needed in the Konflux build. Some packages present in the upstream/midstream Dockerfile can simply be removed (see [trainer](https://github.com/red-hat-data-services/trainer/blob/rhoai-3.5-ea.1/cmd/trainer-controller-manager/Dockerfile.odh): `bind-utils` removed in Dockerfile.konflux rather than prefetched)
  - Other Konflux-general practices that aren't hermeto-specific
- [ ] Renovate guide -- how Renovate auto-updates pinned base image digests in Dockerfiles, and how this interacts with build-arg patterns (currently Renovate scans `FROM` lines for digest pins, so switching to `ARG BASE_IMAGE=...@sha256:...` + `FROM ${BASE_IMAGE}` may require renovate config changes to keep automated updates working)
- [ ] Expand digest pinning section in `dockerfile-productization.md` to cover strategies for renovating an argfile (build-arg file) instead of the Dockerfile itself — e.g., having Renovate update a `.build-args` file that the pipeline passes via `build-arg-file`, so the Dockerfile stays clean and all version pins live in one place

## FIPS Compliance

- [ ] Guide on running check-payload locally to detect FIPS issues before pushing to Konflux. Include common fixes: Go builds (`GOEXPERIMENT=strictfipsruntime`, `-tags strictfipsruntime`, `CGO_ENABLED=1`), FIPS build hardcoding in Dockerfile.konflux (removing dev toggles like `FIPS_ENABLED`), Python/OpenSSL considerations

## Conforma Compliance

- [ ] Getting your build to pass Conforma compliance checks

## Skills

- [ ] Generalize `refine-guide-hermeto` into a generic `refine-guide` skill — the structure (clone repo, parse pipelines, compare implementation to guide, propose edits) works for any guide. Extract hermeto-specific logic (package manager enumeration, prefetch-input parsing) into parameters.

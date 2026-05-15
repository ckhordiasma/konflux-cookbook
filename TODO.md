# Guides TODO



## Hermetic Builds — Open Questions


## Dockerfile.konflux Productization best practices 

- [x] Guide on creating a Dockerfile.konflux from an upstream Dockerfile — see [dockerfile-productization.md](guides/dockerfile-productization.md)
- [ ] Renovate guide -- how Renovate auto-updates pinned base image digests in Dockerfiles, and how this interacts with build-arg patterns (currently Renovate scans `FROM` lines for digest pins, so switching to `ARG BASE_IMAGE=...@sha256:...` + `FROM ${BASE_IMAGE}` may require renovate config changes to keep automated updates working)
- [ ] Expand digest pinning section in `dockerfile-productization.md` to cover strategies for renovating an argfile (build-arg file) instead of the Dockerfile itself — e.g., having Renovate update a `.build-args` file that the pipeline passes via `build-arg-file`, so the Dockerfile stays clean and all version pins live in one place

## FIPS Compliance

- [ ] Guide on running check-payload locally to detect FIPS issues before pushing to Konflux. Include common fixes: Go builds (`GOEXPERIMENT=strictfipsruntime`, `-tags strictfipsruntime`, `CGO_ENABLED=1`), FIPS build hardcoding in Dockerfile.konflux (removing dev toggles like `FIPS_ENABLED`), Python/OpenSSL considerations

## Conforma Compliance

- [ ] Getting your build to pass Conforma compliance checks

## Skills

- [ ] Generalize `refine-guide-hermeto` into a generic `refine-guide` skill — the structure (clone repo, parse pipelines, compare implementation to guide, propose edits) works for any guide. Extract hermeto-specific logic (package manager enumeration, prefetch-input parsing) into parameters.

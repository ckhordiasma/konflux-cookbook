# Guides TODO

## Prerequisites

- [ ] Getting a local build working on x86 or arm before moving to Konflux

## Multi-Arch

- [ ] Provisioning Power/Z architecture hardware on Beaker

## Hermetic Builds with Hermeto

- [ ] Using Hermeto locally to prefetch dependencies, and modifying your build to consume prefetched dependencies
- [ ] Running Hermeto as a container (for environments where you can't install it directly)
- [ ] Python-specific Hermeto gotchas
- [ ] RPM-specific Hermeto gotchas
- [ ] Leveraging AIPCC Python wheel releases

## Dockerfile.konflux Best Practices

- [ ] Guide on creating a Dockerfile.konflux from an upstream Dockerfile -- covers base image pinning by digest, build-arg simplification (hardcoding variant-specific values), label changes, and other Konflux-general practices that aren't hermeto-specific
- [ ] Renovate guide -- how Renovate auto-updates pinned base image digests in Dockerfiles, and how this interacts with build-arg patterns (currently Renovate scans `FROM` lines for digest pins, so switching to `ARG BASE_IMAGE=...@sha256:...` + `FROM ${BASE_IMAGE}` may require renovate config changes to keep automated updates working)

## Conforma Compliance

- [ ] Getting your build to pass Conforma compliance checks

## Validating with Konflux PR Builds

- [ ] Creating a temporary pull request pipeline to test builds before merging (see existing guide: `create-pr-pipeline`)

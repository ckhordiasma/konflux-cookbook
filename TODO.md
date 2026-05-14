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

### Investigation

- [ ] [model-metadata-collection](https://github.com/red-hat-data-services/model-metadata-collection) — Dockerfile.konflux has zero network access (pure data container: only COPYs YAML files), yet pipeline has `prefetch-input: {"type": "gomod", "path": "."}` and `hermetic: true`. Investigate whether this is for SBOM/provenance tracking, or if there's another reason. If SBOM-only, consider documenting the "data-only container" pattern in the guide.

### Repo Cleanup

- [ ] [llama-stack-provider-trustyai-garak](https://github.com/red-hat-data-services/llama-stack-provider-trustyai-garak) — remove vestigial dummy Cargo project (`Cargo.toml`, `Cargo.lock`, `.konflux/main.rs`) and per-arch pip workaround files (`.konflux/s390x`, `.konflux/ppc64le`, `.konflux/prep-hermeto.sh`). These were workarounds for hermeto bugs ([#1205](https://github.com/hermetoproject/hermeto/issues/1205)) that are no longer used now that AIPCC provides prebuilt wheels.
- [ ] [distributed-workloads](https://github.com/red-hat-data-services/distributed-workloads) — `[tool.uv]` config (index-url, index-strategy, environments) is in `pyproject.toml`, which may cause merge conflicts when syncing from upstream. Consider moving these settings to CLI flags in a compile script or Makefile instead.

### AIPCC Guide Improvements

- [ ] Document `-test` index variants (e.g., `cpu-ubi9-test/simple/`) that carry midstream/pre-release builds like `vllm==0.18.0+rhaiv.4` — found in llm-d-kv-cache and llama-stack-provider repos
- [ ] Clarify the two URL prefixes (`console.redhat.com` vs `packages.redhat.com`) — both work, repos use them interchangeably

#### Repos currently leveraging AIPCC wheels (rhoai-3.5-ea.1)

- [distributed-workloads](https://github.com/red-hat-data-services/distributed-workloads) — CPU/CUDA/ROCm training images (th06-cpu, th06-cuda, th06-rocm)
- [kserve-autogluon-server](https://github.com/red-hat-data-services/kserve-autogluon-server) — CPU index for autogluon serving
- [llama-stack-provider-trustyai-garak](https://github.com/red-hat-data-services/llama-stack-provider-trustyai-garak) — CPU base image + AIPCC index
- [llm-d-kv-cache](https://github.com/red-hat-data-services/llm-d-kv-cache) — CPU base image + AIPCC index (uds_tokenizer service)
- [mlflow](https://github.com/red-hat-data-services/mlflow) — mixed AIPCC + PyPI requirements
- [mlserver](https://github.com/red-hat-data-services/mlserver) — CPU requirements
- [notebooks](https://github.com/red-hat-data-services/notebooks) — CPU/CUDA/ROCm base images and workbenches
- [pipelines-components](https://github.com/red-hat-data-services/pipelines-components) — automl + autorag components
- [spark-operator](https://github.com/red-hat-data-services/spark-operator) — CPU index for Spark dependencies

### Refine Hermeto Guide Against Real Repos

Run `/refine-guide-hermeto` against repos with working hermetic builds to find gaps
in the guide. Source: `konflux-central` branch `rhoai-3.5-ea.1` pipelineruns.

#### Fully hermetic — single component

- [x] [odh-dashboard](https://github.com/red-hat-data-services/odh-dashboard) — `odh-dashboard` component
- [x] [data-science-pipelines-operator](https://github.com/red-hat-data-services/data-science-pipelines-operator) — gomod only, zero hermetic Dockerfile changes
- [x] [eval-hub](https://github.com/red-hat-data-services/eval-hub) — gomod only, zero hermetic Dockerfile changes
- [x] [kserve-autogluon-server](https://github.com/red-hat-data-services/kserve-autogluon-server) — pip/AIPCC only, zero hermetic Dockerfile changes, local path deps pattern
- [x] [kube-auth-proxy](https://github.com/red-hat-data-services/kube-auth-proxy) — gomod only, zero hermetic Dockerfile changes, Go workspace (`go.work`) covers multi-module deps
- [x] [kube-rbac-proxy](https://github.com/red-hat-data-services/kube-rbac-proxy) — gomod only, zero hermetic Dockerfile changes, `go mod vendor` + `-mod=vendor` pattern works with prefetched cache
- [x] [kuberay](https://github.com/red-hat-data-services/kuberay) — gomod only, zero hermetic Dockerfile changes, `path` matches `path-context` for subdirectory builds
- [x] [llama-stack-provider-trustyai-garak](https://github.com/red-hat-data-services/llama-stack-provider-trustyai-garak) — pip/AIPCC + RPMs, zero hermetic Dockerfile changes, git dep migrated to AIPCC, permissive mode, CodeReady Builder repos
- [x] [llm-d-kv-cache](https://github.com/red-hat-data-services/llm-d-kv-cache) — pip/AIPCC only, zero hermetic Dockerfile changes, `uv export` workflow, bad hash workaround
- [x] [mlflow](https://github.com/red-hat-data-services/mlflow) — pip/AIPCC + PyPI + yarn + RPMs, mixed-source pattern with `--no-deps`, stock UBI9 (no AIPCC base image), multi-arch compile.py, RHOAI push `hermetic: false` pending yarn support
- [x] [mlflow-operator](https://github.com/red-hat-data-services/mlflow-operator) — gomod only, zero hermetic Dockerfile changes, `replace` directive unifies multi-module (`api/`) under single gomod entry
- [x] [mlserver](https://github.com/red-hat-data-services/mlserver) — pip/AIPCC only, zero hermetic Dockerfile changes, installs by package name not `-r requirements.txt`
- [x] [model-metadata-collection](https://github.com/red-hat-data-services/model-metadata-collection) — gomod only, zero hermetic Dockerfile changes, data-only container (no `go build` in Dockerfile), prefetch likely for SBOM/provenance only
- [x] [model-registry-operator](https://github.com/red-hat-data-services/model-registry-operator) — gomod only, zero hermetic Dockerfile changes, FIPS build flags (`strictfipsruntime`)
- [x] [models-perf-benchmark-data](https://github.com/red-hat-data-services/models-perf-benchmark-data) — no prefetch, zero hermetic Dockerfile changes, data-only container (COPYs JSON files), `hermetic: true` without `prefetch-input`
- [x] [must-gather](https://github.com/red-hat-data-services/must-gather) — no prefetch, zero hermetic Dockerfile changes, `hermetic: true` without `prefetch-input`, network access eliminated via multi-stage `COPY --from=` (kubectl) and Git LFS (helm)
- [x] [odh-cli](https://github.com/red-hat-data-services/odh-cli) — gomod (2 entries: root + yq submodule) + pip + RPMs, zero hermetic Dockerfile changes, git submodule replaces curl for yq, `ose-cli-rhel9` base eliminates kubectl/oc download
- [x] [ogx-k8s-operator](https://github.com/red-hat-data-services/ogx-k8s-operator) — gomod only, zero hermetic Dockerfile changes, two components (ogx-k8s-operator + llama-stack-k8s-operator) sharing same Dockerfile.konflux
- [ ] [rhods-operator](https://github.com/red-hat-data-services/rhods-operator)
- [x] [spark-operator](https://github.com/red-hat-data-services/spark-operator) — gomod + pip/AIPCC + RPMs, EPEL for tini, installs by package name not `-r requirements.txt`
- [ ] [trainer](https://github.com/red-hat-data-services/trainer)
- [ ] [training-operator](https://github.com/red-hat-data-services/training-operator)
- [ ] [trustyai-explainability](https://github.com/red-hat-data-services/trustyai-explainability)
- [ ] [workload-variant-autoscaler](https://github.com/red-hat-data-services/workload-variant-autoscaler)

#### Fully hermetic — multi-component

- [ ] [ai-gateway-payload-processing](https://github.com/red-hat-data-services/ai-gateway-payload-processing) — 2 components: main build, e2e
- [ ] [argo-workflows](https://github.com/red-hat-data-services/argo-workflows) — 2 components: argoexec, workflowcontroller
- [ ] [batch-gateway](https://github.com/red-hat-data-services/batch-gateway) — 3 components: apiserver, gc, processor
- [ ] [data-science-pipelines](https://github.com/red-hat-data-services/data-science-pipelines) — 5 components: api-server-v2, driver, launcher, persistenceagent-v2, scheduledworkflow-v2
- [ ] [kubeflow](https://github.com/red-hat-data-services/kubeflow) — 2 components: kf-notebook-controller, notebook-controller
- [ ] [llm-d-inference-scheduler](https://github.com/red-hat-data-services/llm-d-inference-scheduler) — 2 components: inference-scheduler, routing-sidecar
- [ ] [models-as-a-service](https://github.com/red-hat-data-services/models-as-a-service) — 2 components: maas-api, maas-controller
- [ ] [odh-model-controller](https://github.com/red-hat-data-services/odh-model-controller) — 2 components: model-controller, model-serving-api
- [ ] [rhaii-cluster-validation](https://github.com/red-hat-data-services/rhaii-cluster-validation) — 2 components: cluster-validator, validator-tools

#### Partially hermetic (some components hermetic, some not)

- [ ] [kserve](https://github.com/red-hat-data-services/kserve) — 6/7 hermetic (storage-initializer is not)
- [x] [distributed-workloads](https://github.com/red-hat-data-services/distributed-workloads) — 3/11 hermetic (th06-cpu/cuda130/rocm64; odh-training-* images are not), `uv pip install` requires explicit `--no-index --find-links`, `unsafe-best-match` strategy
- [ ] [RHOAI-Build-Config](https://github.com/red-hat-data-services/RHOAI-Build-Config) — 2/4 hermetic (operator-bundle, fbc-fragment; chart builds are not)
- [x] [pipelines-components](https://github.com/red-hat-data-services/pipelines-components) — 2/3 hermetic (automl, autorag; main build is not), AIPCC + PyPI mixed sources, generic fetcher for ML models/SQLite, AIPCC test index
- [ ] [feast](https://github.com/red-hat-data-services/feast) — 1/2 hermetic (feast-operator; feature-server is not)
- [ ] [model-registry](https://github.com/red-hat-data-services/model-registry) — 1/2 hermetic (model-registry; job-async-upload is not)
- [ ] [trustyai-service-operator](https://github.com/red-hat-data-services/trustyai-service-operator) — 1/2 hermetic (operator; ta-lmes-driver is not)
- [x] [notebooks](https://github.com/red-hat-data-services/notebooks) — 1/18 hermetic (codeserver-datascience-cpu only; rest pending AIPCC-7795), argfile multi-variant pattern, transitional `hermetic: false` + `prefetch-input`

## Dockerfile.konflux Best Practices

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
  - Other Konflux-general practices that aren't hermeto-specific
- [ ] Renovate guide -- how Renovate auto-updates pinned base image digests in Dockerfiles, and how this interacts with build-arg patterns (currently Renovate scans `FROM` lines for digest pins, so switching to `ARG BASE_IMAGE=...@sha256:...` + `FROM ${BASE_IMAGE}` may require renovate config changes to keep automated updates working)

## Conforma Compliance

- [ ] Getting your build to pass Conforma compliance checks

## Validating with Konflux PR Builds

- [ ] Creating a temporary pull request pipeline to test builds before merging (see existing guide: `create-pr-pipeline`)

## Skills

- [ ] Generalize `refine-guide-hermeto` into a generic `refine-guide` skill — the structure (clone repo, parse pipelines, compare implementation to guide, propose edits) works for any guide. Extract hermeto-specific logic (package manager enumeration, prefetch-input parsing) into parameters.

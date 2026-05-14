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

### Refine Hermeto Guide Against Real Repos

Run `/refine-guide-hermeto` against repos with working hermetic builds to find gaps
in the guide. Source: `konflux-central` branch `rhoai-3.5-ea.1` pipelineruns.

#### Fully hermetic — single component

- [x] [odh-dashboard](https://github.com/red-hat-data-services/odh-dashboard) — `odh-dashboard` component
- [x] [data-science-pipelines-operator](https://github.com/red-hat-data-services/data-science-pipelines-operator) — gomod only, zero hermetic Dockerfile changes
- [x] [eval-hub](https://github.com/red-hat-data-services/eval-hub) — gomod only, zero hermetic Dockerfile changes
- [x] [kserve-autogluon-server](https://github.com/red-hat-data-services/kserve-autogluon-server) — pip/AIPCC only, zero hermetic Dockerfile changes, local path deps pattern
- [x] [kube-auth-proxy](https://github.com/red-hat-data-services/kube-auth-proxy) — gomod only, zero hermetic Dockerfile changes, Go workspace (`go.work`) covers multi-module deps
- [ ] [kube-rbac-proxy](https://github.com/red-hat-data-services/kube-rbac-proxy)
- [ ] [kuberay](https://github.com/red-hat-data-services/kuberay)
- [ ] [llama-stack-provider-trustyai-garak](https://github.com/red-hat-data-services/llama-stack-provider-trustyai-garak)
- [ ] [llm-d-kv-cache](https://github.com/red-hat-data-services/llm-d-kv-cache)
- [ ] [mlflow-operator](https://github.com/red-hat-data-services/mlflow-operator)
- [ ] [mlserver](https://github.com/red-hat-data-services/mlserver)
- [ ] [model-metadata-collection](https://github.com/red-hat-data-services/model-metadata-collection)
- [ ] [model-registry-operator](https://github.com/red-hat-data-services/model-registry-operator)
- [ ] [models-perf-benchmark-data](https://github.com/red-hat-data-services/models-perf-benchmark-data)
- [ ] [must-gather](https://github.com/red-hat-data-services/must-gather)
- [ ] [odh-cli](https://github.com/red-hat-data-services/odh-cli)
- [ ] [ogx-k8s-operator](https://github.com/red-hat-data-services/ogx-k8s-operator)
- [ ] [rhods-operator](https://github.com/red-hat-data-services/rhods-operator)
- [ ] [spark-operator](https://github.com/red-hat-data-services/spark-operator)
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
- [ ] [distributed-workloads](https://github.com/red-hat-data-services/distributed-workloads) — 3/11 hermetic (th06-cpu/cuda130/rocm64; odh-training-* images are not)
- [ ] [RHOAI-Build-Config](https://github.com/red-hat-data-services/RHOAI-Build-Config) — 2/4 hermetic (operator-bundle, fbc-fragment; chart builds are not)
- [ ] [pipelines-components](https://github.com/red-hat-data-services/pipelines-components) — 2/3 hermetic (automl, autorag; main build is not)
- [ ] [feast](https://github.com/red-hat-data-services/feast) — 1/2 hermetic (feast-operator; feature-server is not)
- [ ] [model-registry](https://github.com/red-hat-data-services/model-registry) — 1/2 hermetic (model-registry; job-async-upload is not)
- [ ] [trustyai-service-operator](https://github.com/red-hat-data-services/trustyai-service-operator) — 1/2 hermetic (operator; ta-lmes-driver is not)
- [ ] [notebooks](https://github.com/red-hat-data-services/notebooks) — 1/18 hermetic (codeserver-datascience-cpu only; rest pending AIPCC-7795)

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
  - Other Konflux-general practices that aren't hermeto-specific
- [ ] Renovate guide -- how Renovate auto-updates pinned base image digests in Dockerfiles, and how this interacts with build-arg patterns (currently Renovate scans `FROM` lines for digest pins, so switching to `ARG BASE_IMAGE=...@sha256:...` + `FROM ${BASE_IMAGE}` may require renovate config changes to keep automated updates working)

## Conforma Compliance

- [ ] Getting your build to pass Conforma compliance checks

## Validating with Konflux PR Builds

- [ ] Creating a temporary pull request pipeline to test builds before merging (see existing guide: `create-pr-pipeline`)

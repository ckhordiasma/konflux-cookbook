# How to Run Conforma (Enterprise Contract) Validation

This guide walks through running Enterprise Contract (EC) validation to check whether your built images comply with a release policy. You can validate either a full Konflux snapshot (all components in an application) or a single container image.

## Why

Before images can ship through a release pipeline, they must pass Conforma (Enterprise Contract) policy checks. Running validation manually is useful when you need to:

- Debug why a release is being blocked by policy failures
- Test your images against a different or updated policy
- Validate a specific snapshot before triggering a release
- Understand which components are failing and why

## Important: Conforma requires Konflux-built images

Conforma validates artifacts that are produced during the Konflux build pipeline — image signatures, attestations, SBOMs, and build provenance. These artifacts don't exist for locally-built images, so conforma will fail against them.

This means you can run conforma against images built by a Konflux pipeline (push builds, pull request builds, etc.), but **not** against images you built locally (e.g. with `podman build` or `docker build`).

## Prerequisites

You need the following tools installed and configured:
- **`kubectl`** -- Kubernetes CLI, logged into the Konflux cluster
- **`ec`** -- [Enterprise Contract CLI](https://github.com/enterprise-contract/ec-cli)
- **`jq`** -- JSON processor (only needed for snapshot-based validation)

### Authenticating kubectl with oc login

The easiest way to authenticate `kubectl` against an OpenShift cluster is to use `oc login --web`, which opens a browser for SSO authentication. The `oc` CLI writes credentials to your kubeconfig (`~/.kube/config`), and `kubectl` reads the same file — so after logging in, `kubectl` commands just work:

```bash
oc login --web --server=https://api.stone-prod-p02.hjvn.p1.openshiftapps.com:6443/
kubectl get namespaces   # works immediately — uses the same kubeconfig
```

You only need `oc` for the initial login. All other commands in this guide use `kubectl`.

The Konflux cluster API URLs are:
- **rh01** (midstream ODH builds): `https://api.stone-prd-rh01.pg1f.p1.openshiftapps.com:6443/`
- **p02** (downstream RHOAI builds): `https://api.stone-prod-p02.hjvn.p1.openshiftapps.com:6443/`

See the [Konflux cluster info page](https://konflux.pages.redhat.com/docs/users/cluster-info/cluster-info.html) for the full list.

## Getting a Policy File

The `ec validate image` command requires a `--policy` argument that tells it which rules to check against. You can specify this as:

- **A Kubernetes reference** — use the policy name directly if you're logged into the Konflux cluster with `kubectl`: `--policy rhtap-releng-tenant/registry-rhoai-prod`
- **A local YAML file** — download the policy definition and reference it locally: `--policy registry-rhoai-prod.yaml`

For RHOAI, the production release policy is `rhtap-releng-tenant/registry-rhoai-prod`. Its definition lives in [konflux-release-data](https://gitlab.cee.redhat.com/releng/konflux-release-data/-/blob/main/config/stone-prod-p02.hjvn.p1/product/EnterpriseContractPolicy/registry-rhoai-prod.yaml). You can download it from that GitLab URL or from the cluster with `kubectl`:

```bash
kubectl get enterprisecontractpolicy registry-rhoai-prod \
  -n rhtap-releng-tenant -o yaml > registry-rhoai-prod.yaml
```

## Validate a Single Image

Use this when onboarding a new component or testing build changes — validate the image from your PR build to catch policy issues before merging. To validate all components in an application at once, see [Appendix: Validate a Full Snapshot](#appendix-validate-a-full-snapshot).

### 1. Run EC validation against the image

```bash
ec validate image \
  --ignore-rekor true \
  --image quay.io/your-org/your-image:tag \
  --public-key k8s://openshift-pipelines/public-key \
  --policy registry-rhoai-prod.yaml \
  --info \
  --output yaml \
  --timeout 30m0s
```

Replace `--image` with the full image reference (including tag or digest). You can also use a digest reference like `quay.io/your-org/your-image@sha256:abc123...`.

### 2. Review the results

Check the exit code:

- **0** -- the image passed policy validation
- **non-zero** -- the image failed

The YAML output contains the detailed results. Add `--verbose` for more detail when debugging failures.

If your image didn't pass, see [Fixing Conforma Failures](#fixing-conforma-failures).

## Validate Release Policy

Before images ship through a release pipeline, they must pass Conforma validation. Conforma checks happen at two points in the RHOAI release process:

The RHOAI production release policy is `rhtap-releng-tenant/registry-rhoai-prod` on the Konflux cluster. Its definition lives in [konflux-release-data](https://gitlab.cee.redhat.com/releng/konflux-release-data/-/blob/main/config/stone-prod-p02.hjvn.p1/product/EnterpriseContractPolicy/registry-rhoai-prod.yaml).

1. **During development** — manually run `ec validate image` against PR build images to catch policy issues early (see [Validate a Single Image](#validate-a-single-image) above).

2. **At release time** — Conforma runs automatically via IntegrationTestScenario on release branches. Failures at this stage block the release. The DevOps team can use [Validate a Full Snapshot](#appendix-validate-a-full-snapshot) to debug which components are failing and why.

Running validation early — during PR builds — avoids surprises at release time. If you're deploying a new component or making significant build changes, validate before merging to the release branch.

## Fixing Conforma Failures

Conforma failures mean an image doesn't meet productization standards. The fix is typically in the image build itself. Use `--verbose` with `ec validate image` to see exactly which policy rule failed.

Some examples of failure categories and where to fix them:

| Failure area | What it means | Where to fix |
|-------------|---------------|--------------|
| Missing or invalid image signature | Image wasn't built through a Konflux pipeline | Locally-built images cannot pass — the image must be built by Konflux. See [deploying-to-konflux](deploying-to-konflux.md). |
| Missing attestation or SBOM | Prefetch configuration is incomplete or hermetic build is not enabled | Review your `prefetch-input` and set `hermetic: true`. See [hermeto-prefetch](hermeto-prefetch.md). |
| FIPS compliance | Go binary missing FIPS flags, or non-certified crypto libraries in the image | Run [check-payload](check-payload.md) locally to diagnose, then fix in your Dockerfile.konflux per the [FIPS section](dockerfile-productization.md#fips-compliance). |
| Base image not from approved source | Using community images instead of UBI/RHEL | Switch to UBI base images. See [Base Image Changes](dockerfile-productization.md#base-image-changes). |
| Base image not pinned by digest | `FROM` line uses a floating tag | Pin by digest. See [Base Image Pinning](dockerfile-productization.md#base-image-pinning-by-digest). |

### Testing with policy exceptions locally

If a failure cannot be fixed immediately in the build (e.g., a known issue awaiting an upstream fix), you can test whether a policy exception would let your component pass. Download the production policy, add an exception, and re-validate locally:

1. Download the policy (see [Getting a Policy File](#getting-a-policy-file)):

```bash
kubectl get enterprisecontractpolicy registry-rhoai-prod \
  -n rhtap-releng-tenant -o yaml > registry-rhoai-prod-local.yaml
```

2. Edit `registry-rhoai-prod-local.yaml` to add an exception for the failing rule. Exceptions are added under `spec.configuration.exclude`:

```yaml
spec:
  configuration:
    exclude:
      - "step_image_registries"   # example: skip the base image registry check
```

3. Re-run validation with the modified policy:

```bash
ec validate image \
  --ignore-rekor true \
  --image <your-image> \
  --public-key k8s://openshift-pipelines/public-key \
  --policy registry-rhoai-prod-local.yaml \
  --info \
  --output yaml \
  --timeout 30m0s
```

This lets you verify that adding a specific exception would unblock your component locally. **Policy exceptions require approval from both release engineering and RHOAI product management.** The actual exception must be added to the production policy in [konflux-release-data](https://gitlab.cee.redhat.com/releng/konflux-release-data/-/blob/main/config/stone-prod-p02.hjvn.p1/product/EnterpriseContractPolicy/registry-rhoai-prod.yaml) — you cannot self-service approve MRs to this file. Always prefer fixing the underlying build issue over requesting an exception.

## See Also

- [Deploying Hermetic Build Config to Konflux](deploying-to-konflux.md) — the deployment workflow that uses Conforma validation at multiple stages.
- [check-payload](check-payload.md) — local FIPS compliance checking, complementary to Conforma's broader policy validation.

## Appendix: Validate a Full Snapshot

Use this when you need to validate all components in a Konflux application at once — typically for DevOps teams testing an entire release.

### 1. Choose your application

Identify the Konflux application you want to validate. This is the application name as it appears in Konflux, e.g. `rhoai-v3-4`.

```bash
APPLICATION=rhoai-v3-4
```

### 2. Find the latest snapshot

Snapshots are created by Konflux after successful builds or component changes. To find the most recent push snapshot for your application:

```bash
kubectl get snapshots \
  -l "pac.test.appstudio.openshift.io/event-type notin (pull_request),appstudio.openshift.io/application=$APPLICATION" \
  --sort-by=.metadata.creationTimestamp
```

The latest snapshot is the last row. Note its name:

```bash
SNAPSHOT=<name-from-output>
```

The label selectors filter for:
- `pac.test.appstudio.openshift.io/event-type notin (pull_request)` -- excludes pull request snapshots while including push snapshots and snapshots created without an event-type label (e.g. component removals)
- `appstudio.openshift.io/application=$APPLICATION` -- only snapshots for your application

#### Alternative: use the latest released snapshot

To validate against the snapshot from the most recent release instead of the latest push snapshot, find it via the Release CR:

```bash
SNAPSHOT=$(kubectl get releases \
  -l "appstudio.openshift.io/application=$APPLICATION" \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1:].spec.snapshot}')
```

The `conforma.sh` script supports this directly with `--latest-rc`:

```bash
./scripts/conforma.sh --application rhoai-v3-4 --latest-rc
```

You can also specify a snapshot directly without an application — the script will derive the application name from the snapshot:

```bash
./scripts/conforma.sh --snapshot <snapshot-name>
```

### 3. Download and filter the snapshot

Download the snapshot as JSON and filter out FBC (File-Based Catalog) fragment components, which are not subject to the same policy checks:

```bash
kubectl get snapshot $SNAPSHOT -o json \
  | jq '.spec.components |= [.[] | select(.name | test("fbc-fragment") | not)]' \
  > snapshot.json
```

To validate only specific components, add a regex filter on the component name. For example, to validate only components whose name contains `odh-notebook`:

```bash
kubectl get snapshot $SNAPSHOT -o json \
  | jq '.spec.components |= [.[] | select(.name | test("fbc-fragment") | not)]
        | .spec.components |= [.[] | select(.name | test("odh-notebook"))]' \
  > snapshot.json
```

Check how many components are in the snapshot:

```bash
jq '.spec.components | length' snapshot.json
```

### 4. Verify the snapshot

Confirm the snapshot belongs to the application you expect:

```bash
jq -r '.spec.application' snapshot.json
```

This should print your application name. If it doesn't match, you grabbed the wrong snapshot.

### 5. Run EC validation

Run `ec validate image` against the snapshot:

```bash
ec validate image \
  --ignore-rekor true \
  --workers 50 \
  --file-path snapshot.json \
  --public-key k8s://openshift-pipelines/public-key \
  --policy $POLICY \
  --info \
  --output yaml \
  --timeout 30m0s
```

Flag reference:

| Flag | Purpose |
|------|---------|
| `--ignore-rekor true` | Skip Rekor transparency log verification |
| `--workers 50` | Number of concurrent validation workers (increase for large snapshots) |
| `--file-path` | Path to the snapshot JSON file |
| `--public-key` | Public key used to verify image signatures. `k8s://openshift-pipelines/public-key` references a secret in the cluster |
| `--policy` | Policy configuration to validate against (see [Getting a Policy File](#getting-a-policy-file)) |
| `--info` | Include informational (non-blocking) results |
| `--output yaml` | Output format |
| `--timeout 30m0s` | Timeout for the entire validation run |

To save the output to a file:

```bash
ec validate image \
  --ignore-rekor true \
  --workers 50 \
  --file-path snapshot.json \
  --public-key k8s://openshift-pipelines/public-key \
  --policy $POLICY \
  --info \
  --output yaml \
  --timeout 30m0s \
  | tee ec-report.yaml
```

Add `--verbose` for detailed output, which is helpful when debugging specific policy failures.

### 6. Review the results

Check the exit code of the `ec` command:

- **0** -- all components passed policy validation
- **non-zero** -- one or more components failed

The YAML output contains per-component results. Look for components with failures to understand what policy rules they violated.

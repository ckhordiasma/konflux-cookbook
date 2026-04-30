# How to Run Conforma (Enterprise Contract) Validation Against a Konflux Snapshot

This guide walks through running Enterprise Contract (EC) validation against a Konflux snapshot to check whether your built images comply with a release policy.

## Why

Before images can ship through a release pipeline, they must pass Conforma (Enterprise Contract) policy checks. Running validation manually is useful when you need to:

- Debug why a release is being blocked by policy failures
- Test your images against a different or updated policy
- Validate a specific snapshot before triggering a release
- Understand which components are failing and why

## Prerequisites

You need the following tools installed and configured:

- **`oc`** -- OpenShift CLI, logged into the Konflux cluster
- **`ec`** -- [Enterprise Contract CLI](https://github.com/enterprise-contract/ec-cli)
- **`jq`** -- JSON processor

## Steps

### 1. Choose your application

Identify the Konflux application you want to validate. This is the application name as it appears in Konflux, e.g. `rhoai-v3-4`.

```bash
APPLICATION=rhoai-v3-4
```

### 2. Find the latest push snapshot

Snapshots are created by Konflux after successful builds. To find the most recent push snapshot for your application:

```bash
oc get snapshots \
  -l "pac.test.appstudio.openshift.io/event-type in (push, Push),appstudio.openshift.io/application=$APPLICATION" \
  --sort-by=.metadata.creationTimestamp
```

The latest snapshot is the last row. Note its name:

```bash
SNAPSHOT=<name-from-output>
```

The label selectors filter for:
- `pac.test.appstudio.openshift.io/event-type in (push, Push)` -- only snapshots created by push (post-merge) builds, not pull request builds
- `appstudio.openshift.io/application=$APPLICATION` -- only snapshots for your application

### 3. Download and filter the snapshot

Download the snapshot as JSON and filter out FBC (File-Based Catalog) fragment components, which are not subject to the same policy checks:

```bash
oc get snapshot $SNAPSHOT -o json \
  | jq '.spec.components |= [.[] | select(.name | test("fbc-fragment") | not)]' \
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

### 5. Choose a policy

EC validates images against a policy configuration. Policies can be specified as:

- **A local YAML file** -- e.g. `registry-rhoai-prod.yaml`
- **A Kubernetes reference** -- e.g. `k8s://tekton-chains/policy`

```bash
POLICY=registry-rhoai-prod.yaml
```

### 6. Run EC validation

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
| `--policy` | Policy configuration to validate against |
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

### 7. Review the results

Check the exit code of the `ec` command:

- **0** -- all components passed policy validation
- **non-zero** -- one or more components failed

The YAML output contains per-component results. Look for components with failures to understand what policy rules they violated.

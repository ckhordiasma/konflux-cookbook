# How to Test Build Changes on an RHOAI Release Branch

This guide explains how to create a temporary pull request PipelineRun in a component repo, based on the existing push PipelineRun for an RHOAI release branch. This lets you verify that build changes (e.g., Dockerfile changes, prefetch config, build parameters) work correctly on a PR before merging into the release branch.

## Why

Pull request pipelines are maintained in the konflux-central main branch and should get synced into component release branches, but in practice the sync may not happen or the parameters may drift from the push pipeline. Rather than debugging sync issues, it's more consistent to create a temporary pull request pipeline directly from the release branch's push pipeline - you know the build parameters match what will actually run on merge.

> **Note:** If your PR also modifies the push pipeline (e.g., adding a new build param or changing the Dockerfile path), after merging you need to make the same change to the corresponding PipelineRun in konflux-central (`pipelineruns/<component>/.tekton/`), since that is the source of truth for what gets synced to component repos.

## Steps

### 1. Copy the release branch push PipelineRun

Start with the push PipelineRun for your target release branch. Push PipelineRuns for release branches are typically named with the branch suffix:

```
.tekton/<component>-<release-branch>-push.yaml
```

Copy it to:

```
.tekton/<component>-pull-request.yaml
```

Make sure you copy the push PipelineRun that matches your target release branch, not the `main` one. Release branch PipelineRuns have different build parameters, image destinations, and branch-specific configuration.

### 2. Change the PipelineRun name

```yaml
# Before
metadata:
  name: <component>-push

# After
metadata:
  name: <component>-pull-request
```

### 3. Modify annotations

**Change** the event from push to pull_request:

```yaml
# Before
pipelinesascode.tekton.dev/on-event: "[push]"

# After
pipelinesascode.tekton.dev/on-event: "[pull_request]"
```

Or, if you want it only triggered manually by comment (recommended for temporary pipelines):

```yaml
# Replace on-event with on-comment
pipelinesascode.tekton.dev/on-comment: "^/build-konflux"
```

If using `on-comment`, **remove** `on-event` and `on-cel-expression` annotations -- they conflict with comment-based triggering.

Keep `on-target-branch` as-is so the pipeline matches the same branches the push pipeline targets.

### 4. Change params

Update the following params:

**git-url** -- push pipelines use `{{repo_url}}`, but pull requests may come from forks:

```yaml
# Before
- name: git-url
  value: '{{repo_url}}'

# After
- name: git-url
  value: '{{source_url}}'
```

**revision** -- build the PR commit instead of the target branch:

```yaml
# Before
- name: revision
  value: '{{target_branch}}'

# After
- name: revision
  value: '{{revision}}'
```

**output-image** -- push pipelines push to a production quay repo. Change to the pull request pipelines repo instead. This is critical -- if you leave the push repo, your test build could overwrite a production image:

```yaml
# Before
- name: output-image
  value: 'quay.io/redhat-user-workloads/.../<component>:{{target_branch}}'

# After
- name: output-image
  value: 'quay.io/redhat-user-workloads/rhoai-tenant/pull-request-pipelines/<component>:on-pr-{{revision}}'
```

**image-expires-after** -- add an expiration so test images don't accumulate:

```yaml
- name: image-expires-after
  value: 5d
```

**enable-slack-failure-notification** -- disable for test builds:

```yaml
- name: enable-slack-failure-notification
  value: "false"
```

### 5. Optionally test a specific pipeline branch

If you also want to test pipeline changes from a konflux-central PR, change the `pipelineRef` revision:

```yaml
pipelineRef:
  resolver: git
  params:
  - name: url
    value: https://github.com/red-hat-data-services/konflux-central.git
  - name: revision
    value: 'my-pipeline-branch'    # <-- instead of target_branch
  - name: pathInRepo
    value: pipelines/multi-arch-container-build.yaml
```

Otherwise, leave the `pipelineRef` as-is to use the same pipeline version as the push build.

### 6. Change the service account

The push pipeline's service account has push credentials for the production repo. Change it to the pull request pipelines service account so it has permission to push to the pull request quay repo:

```yaml
# Before
spec:
  serviceAccountName: build-pipeline-<component>

# After
spec:
  serviceAccountName: build-pipeline-pull-request-pipelines
```

### 7. Keep everything else the same

Preserve the component's build configuration as-is:
- `dockerfile`
- `path-context`
- `hermetic`
- `prefetch-input`
- `build-platforms`
- `build-source-image`
- `build-image-index`
- `additional-labels`

These ensure the test build matches what the component actually does in production.

## Example Diff

Push pipeline (`.tekton/odh-cli-rhoai-2.19-push.yaml`):

```yaml
metadata:
  name: odh-cli-rhoai-2.19-push
  annotations:
    pipelinesascode.tekton.dev/on-event: "[push]"
    pipelinesascode.tekton.dev/on-target-branch: "[rhoai-2.19]"
spec:
  serviceAccountName: build-pipeline-odh-cli
...
- name: git-url
  value: '{{repo_url}}'
- name: revision
  value: '{{target_branch}}'
- name: output-image
  value: 'quay.io/redhat-user-workloads/.../odh-cli:{{target_branch}}'
```

Converted pull request pipeline (`.tekton/odh-cli-pull-request.yaml`):

```yaml
metadata:
  name: odh-cli-pull-request
  annotations:
    pipelinesascode.tekton.dev/on-comment: "^/build-konflux"
    pipelinesascode.tekton.dev/on-target-branch: "[rhoai-2.19]"
spec:
  serviceAccountName: build-pipeline-pull-request-pipelines
...
- name: git-url
  value: '{{source_url}}'
- name: revision
  value: '{{revision}}'
- name: output-image
  value: 'quay.io/redhat-user-workloads/rhoai-tenant/pull-request-pipelines/odh-cli:on-pr-{{revision}}'
- name: image-expires-after
  value: 5d
- name: enable-slack-failure-notification
  value: "false"
```

## Triggering the Build

If using `on-comment`, comment on your PR:

```
/build-konflux
```

If using `on-event: "[pull_request]"`, the build triggers automatically when you open or update the PR.

## Cleanup

Remove the `.tekton/<component>-pull-request.yaml` file before merging your PR (or in a follow-up revert commit), since it's only needed for testing.

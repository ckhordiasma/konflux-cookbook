# Deploying Hermetic Build Config to Konflux

This guide covers how to get your locally-working hermetic build configuration into actual Konflux builds for RHOAI components. It picks up where the [hermeto prefetch guide](hermeto-prefetch.md) leaves off -- you have a working hermetic build locally, and now you need to apply that configuration to the Konflux pipelines that build your component.

This guide is specific to the productization workflow for OpenShift AI (RHOAI) components. It assumes familiarity with the midstream (opendatahub-io) and downstream (red-hat-data-services) repo structure.

This guide walks through the full path: midstream ODH first, then downstream RHDS. Starting with midstream shifts left on Konflux build issues, catching them earlier in the development cycle before they reach the production release pipelines. If you only need to update downstream builds, skip ahead to [Apply to Downstream RHDS Builds](#apply-to-downstream-rhds-builds).

## Prerequisites

- Your component is already onboarded for Konflux builds in both midstream (opendatahub-io) and downstream (red-hat-data-services)
- You have a working hermetic build locally (see the [hermeto prefetch guide](hermeto-prefetch.md))
- You have the files ready to commit: pinned requirements files, `rpms.in.yaml`/`rpms.lock.yaml` if applicable, and `Dockerfile.konflux` changes

## Apply to Midstream ODH Builds

This section applies your changes through the midstream opendatahub-io pipeline infrastructure.

### Step 1: PR to odh-konflux-central

PR the required PipelineRun changes into your component's folder in [odh-konflux-central](https://github.com/opendatahub-io/odh-konflux-central/tree/main/pipelineruns).

The main change is the `prefetch-input` parameter -- this is where the hermeto JSON config goes. Copy the contents of your `hermeto-test.json` (the config you developed locally) into this parameter. For the config format and fields, see [Configuring hermeto-test.json](hermeto-prefetch.md#configuring-hermeto-testjson).

```yaml
- name: prefetch-input
  value: '[{"type": "pip", "path": ".", "requirements_files": ["requirements.txt"], "binary": {"arch": "x86_64,aarch64,ppc64le,s390x"}}, {"type": "rpm", "path": "."}]'
```

If your build is fully working as hermetic, you can also set:

```yaml
- name: hermetic
  value: "true"
```

Other parameters you may need to update:
- **`dockerfile`** -- if your hermetic build uses a different Dockerfile name (e.g., `Dockerfile.konflux`)
- **`path-context`** -- if your build context is a subdirectory

**Build platforms:** Even if you tested multi-arch locally, leave the build platforms set to just x86_64 in the midstream PipelineRun. Running multi-arch builds adds significant load to rh01 (the cluster that ODH Konflux builds run on). Multi-arch builds are configured separately for downstream production pipelines.

### Step 2: Run the ODH Konflux Onboarder

Once your odh-konflux-central PR is merged, run the ODH Konflux onboarder. Select your repo and choose the branch that your CI builds run from (usually `main`). Set the build type to CI and leave the rest blank.

The onboarder creates a PR in your midstream repo with the PipelineRun configuration you added to odh-konflux-central.

From here, you have two approaches:

**Approach A: Iterate on the auto-generated PR.** Add commits to the onboarder's PR with the changes you developed locally -- Dockerfile.konflux, pinned requirements files, rpms.in.yaml/rpms.lock.yaml, and any other files needed for the hermetic build. Each push triggers a Konflux pull request build, which you can watch to verify your build is working.

**Approach B: Merge first, then PR your changes separately.** Merge the auto-generated PR as-is, then open a separate PR with your hermetic build changes.
- You can verify things work with a pull request build on this second PR
- CI push builds will be broken between the auto-generated merge and your PR landing (since the pipeline references files that don't exist yet), so coordinate accordingly

### Step 3: Iterate with PR Builds

Whether you're iterating on the onboarder's PR (Approach A) or on a follow-up PR (Approach B), each push triggers a Konflux pull request build. Watch the build in the Konflux web UI to verify your hermetic build works.

If you need to tweak the PipelineRun itself during iteration (e.g., adjusting your hermeto config in `prefetch-input`, changing the Dockerfile path, or modifying build parameters), you will also need to backport those changes to odh-konflux-central. The PipelineRun in your component repo was generated from odh-konflux-central, and the two need to stay in sync.

If your component repo doesn't already have a pull request PipelineRun, or the existing one doesn't match your release branch's push pipeline, see the [create-pr-pipeline guide](create-pr-pipeline.md) for how to create a temporary one for testing.

### Step 4: Find Your Build Image

Your pull request build produces an image that gets pushed to Quay. To find the image URI and SHA:

1. Open the PipelineRun in the Konflux web UI
2. Navigate to the **Results** section
3. Look for the `IMAGE_URL` and `IMAGE_DIGEST` results

The image reference will look something like:
```
quay.io/redhat-user-workloads/.../<component>@sha256:abc123...
```

### Step 5: Validate with Conforma

With the built image from your PR build, you can run it against the production RHOAI Conforma (Enterprise Contract) policy to catch potential compliance issues before they block a release.

```bash
ec validate image \
  --ignore-rekor true \
  --image <image-uri-from-step-4> \
  --public-key k8s://openshift-pipelines/public-key \
  --policy registry-rhoai-prod.yaml \
  --info \
  --output yaml \
  --timeout 30m0s
```

See the [Conforma validation guide](test-conforma.md) for the full walkthrough, including how to interpret results and debug failures.

## Apply to Downstream RHDS Builds

This section applies your changes to the downstream red-hat-data-services (RHDS) component repo, where production release builds run. Whether you started with midstream or are coming here directly, this is required for your changes to ship.

Unlike the ODH konflux-central workflow, the RHDS konflux-central repo pushes changes directly to the relevant branch of the component repo -- there is no intermediate PR step. This means you work directly in the component repo.

### Step 1: PR Your Hermetic Changes to the RHDS Component Repo

Open a PR against the `main` branch of your RHDS component repo with your hermetic build changes -- `Dockerfile.konflux`, pinned requirements files, `rpms.in.yaml`/`rpms.lock.yaml`, and any other files needed for the build.

### Step 2: Update the Pull Request PipelineRun

The `main` branch should already have a pull request PipelineRun in the `.tekton/` folder that targets the `rhoai-tenant` namespace. Update it with the changes needed for your hermetic build:

- **`prefetch-input`** -- your hermeto JSON config (see [Configuring hermeto-test.json](hermeto-prefetch.md#configuring-hermeto-testjson))
- **`hermetic`** -- set to `"true"` if your build is fully hermetic
- **`dockerfile`** -- if using a different Dockerfile name (e.g., `Dockerfile.konflux`)
- Any other build parameters that changed

### Step 3: Trigger a PR Build

Check the annotations at the top of the pull request PipelineRun. It should include both label and comment triggers. Either:

- **Comment trigger** -- add the appropriate comment to your PR (e.g., `/build-konflux`) for a one-off build
- **Label trigger** -- add the appropriate label to your PR to trigger a build on each push

### Step 4: Conforma Validation

If the PR build succeeds, a second pipeline triggers automatically that checks the built image against the RHOAI production Conforma policy. Review the results and address any failures before merging -- these same checks gate the release pipeline, so fixing them now avoids blocking later.

### Step 5: Sync Changes Back to RHDS Konflux-Central

Once your PR is merged, you need to update two PipelineRun specs in the RHDS konflux-central repo to stay in sync:

1. **Main branch pull request PipelineRun** -- update the PR pipeline spec in konflux-central's `main` branch with any PipelineRun changes you made (prefetch-input, dockerfile, hermetic, etc.)
2. **Release branch push PipelineRun** -- update the push pipeline spec on the corresponding release branch in konflux-central with the same changes

This is necessary because RHDS konflux-central pushes pipeline changes directly to component repos. If you don't sync your changes back, the next pipeline sync from konflux-central will overwrite your updates.

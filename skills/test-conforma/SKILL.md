---
name: test-conforma
description: Run Conforma (Enterprise Contract) validation against a Konflux snapshot or a single image to check release policy compliance
version: 1.0.0
---

# Run Conforma Validation

Read the reference doc at `guides/test-conforma.md` (relative to the plugin root) for the full procedure. Follow the steps below using that doc as your guide.

## Steps

1. **Ask what to validate**: Ask the user whether they want to validate a single image or a full Konflux snapshot.

### Single image path

2. **Get the image reference**: Ask the user for the full image reference (e.g. `quay.io/org/image:tag` or a `@sha256:` digest reference).

3. **Ask for the policy**: Ask which policy to validate against. Default to `registry-rhoai-prod.yaml` if they don't have a preference. The policy can be a local YAML file or a Kubernetes reference.

4. **Run EC validation**: Run `ec validate image` with `--image` as described in the guide (Option A). Save the output to a file. Let the user know this may take a minute.

5. **Summarize results**: Report the exit code (0 = pass, non-zero = failure). If it failed, summarize the policy violations.

### Snapshot path

2. **Ask for the application name**: Ask the user which Konflux application to validate (e.g. `rhoai-v3-4`).

3. **Ask for the policy**: Ask which policy to validate against. Default to `registry-rhoai-prod.yaml` if they don't have a preference. The policy can be a local YAML file or a Kubernetes reference.

4. **Find the latest snapshot**: Run `oc get snapshots` with the label selectors from the guide to find the latest push snapshot. Show the snapshot name to the user and ask them to confirm it's the right one. If the user already knows the snapshot name, skip the lookup.

5. **Download and filter the snapshot**: Run `oc get snapshot <name> -o json` and pipe through `jq` to filter out FBC fragment components. Save to a temp file. Report the component count to the user.

6. **Verify the snapshot**: Check that `.spec.application` in the downloaded JSON matches the expected application name. If it doesn't match, warn the user and stop.

7. **Run EC validation**: Run the `ec validate image` command with `--file-path` as described in the guide (Option B). Use `--workers 50` and `--timeout 30m0s` by default. Save the output to a file named `ec-report-<application>-<policy-stem>.yaml`. This command may take several minutes for large snapshots -- let the user know.

8. **Summarize results**: After validation completes, report:
   - Number of components validated
   - Exit code (0 = pass, non-zero = failures)
   - If there were failures, highlight which components failed and summarize the policy violations

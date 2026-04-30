---
name: test-conforma
description: Run Conforma (Enterprise Contract) validation against a Konflux snapshot to check release policy compliance
version: 1.0.0
---

# Run Conforma Validation

Read the reference doc at `guides/test-conforma.md` (relative to the plugin root) for the full procedure. Follow the steps below using that doc as your guide.

## Steps

1. **Ask for the application name**: Ask the user which Konflux application to validate (e.g. `rhoai-v3-4`).

2. **Ask for the policy**: Ask which policy to validate against. Default to `registry-rhoai-prod.yaml` if they don't have a preference. The policy can be a local YAML file or a Kubernetes reference.

3. **Find the latest snapshot**: Run `oc get snapshots` with the label selectors from the guide to find the latest push snapshot. Show the snapshot name to the user and ask them to confirm it's the right one. If the user already knows the snapshot name, skip the lookup.

4. **Download and filter the snapshot**: Run `oc get snapshot <name> -o json` and pipe through `jq` to filter out FBC fragment components. Save to a temp file. Report the component count to the user.

5. **Verify the snapshot**: Check that `.spec.application` in the downloaded JSON matches the expected application name. If it doesn't match, warn the user and stop.

6. **Run EC validation**: Run the `ec validate image` command as described in the guide. Use `--workers 50` and `--timeout 30m0s` by default. Save the output to a file named `ec-report-<application>-<policy-stem>.yaml`. This command may take several minutes for large snapshots -- let the user know.

7. **Summarize results**: After validation completes, report:
   - Number of components validated
   - Exit code (0 = pass, non-zero = failures)
   - If there were failures, highlight which components failed and summarize the policy violations

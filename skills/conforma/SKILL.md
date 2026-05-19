---
name: conforma
description: Run Conforma (Enterprise Contract) validation against a Konflux snapshot or a single image to check release policy compliance
version: 1.0.0
---

# Run Conforma Validation

Read `guides/conforma.md` (relative to the plugin root) thoroughly before starting. It is the source of truth for all Conforma validation details — do not duplicate its content, reference it as you go.

## Steps

1. **Ask what to validate**: Ask the user whether they want to validate a single image or a full Konflux snapshot.

### Single image path

2. **Get the image reference**: Ask the user for the full image reference (e.g. `quay.io/org/image:tag` or a `@sha256:` digest reference).

3. **Ask for the policy**: Ask which policy to validate against. Default to `registry-rhoai-prod.yaml` if they don't have a preference.

4. **Run EC validation**: Follow Option A in the guide. Let the user know this may take a minute.

5. **Summarize results**: Report the exit code (0 = pass, non-zero = failure). If it failed, summarize the policy violations.

### Snapshot path

2. **Confirm cluster access**: The snapshot path requires `kubectl` access to the Konflux cluster. Confirm the user is authenticated before proceeding.

3. **Get the application and policy**: Ask which Konflux application to validate (e.g. `rhoai-v3-4`) and which policy to use. Default to `registry-rhoai-prod.yaml`.

4. **Find and download the snapshot**: Follow the guide's snapshot lookup, download, and filtering steps. Show the snapshot name and component count to the user for confirmation. If the user wants to validate only specific components, ask for a filter pattern.

5. **Run EC validation**: Follow Option B in the guide. Save the output to `ec-report-<application>-<policy-stem>.yaml`. This may take several minutes for large snapshots — let the user know.

6. **Summarize results**: Report the component count, exit code, and any failures with which components failed and why.

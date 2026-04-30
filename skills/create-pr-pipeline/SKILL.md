---
name: create-pr-pipeline
description: Create a temporary pull request PipelineRun from an existing push PipelineRun to test build changes on an RHOAI release branch
version: 1.0.0
---

# Create a Temporary Pull Request Pipeline

Read the reference doc at `guides/create-pr-pipeline.md` (relative to the plugin root) for the full procedure. Follow the steps below using that doc as your guide.

## Steps

1. **Find the push PipelineRun**: List the `.tekton/` directory and show the user the available push PipelineRuns. Ask them to confirm which one to copy.

2. **Ask about trigger mode**: Ask the user how they want the pipeline triggered:
   - **Automatic**: runs on every PR update (`on-event: "[pull_request]"`)
   - **Manual**: only runs when someone comments `/build-konflux` on the PR (`on-comment: "^/build-konflux"`)

3. **Copy and modify**: Copy the selected push PipelineRun to `.tekton/<component>-pull-request.yaml` and apply all the changes described in the reference doc (name, annotations, params, service account).

4. **After making changes**:
   - Show the user a summary of what was changed
   - Remind them how to trigger the build based on their trigger mode choice
   - Remind them to remove the file before merging
   - If their PR also modifies the push pipeline, remind them to sync that change to konflux-central

---
name: deploying-to-konflux
description: Deploy locally-working hermetic build configuration into Konflux pipelines for RHOAI components
version: 1.0.0
---

# Deploy Hermetic Build Config to Konflux

Read `guides/deploying-to-konflux.md` (relative to the plugin root) thoroughly before starting. It is the source of truth for the deployment workflow — do not duplicate its content, reference it as you go.

## Steps

1. **Determine starting point**: Ask the user:
   - Which component are they deploying?
   - Do they have a working local hermetic build already? (If not, point them to the hermeto-prefetch skill first.)
   - Do they want to start with midstream ODH builds, or go directly to downstream RHDS?
   - Confirm they have `kubectl` access to the Konflux cluster (needed for Conforma validation and snapshot lookups).

2. **Midstream path** (if applicable): Walk through the odh-konflux-central workflow from the guide:
   - Help them prepare the PipelineRun changes (especially `prefetch-input`)
   - Remind them to leave build platforms as x86_64 only for midstream
   - Guide them through the onboarder workflow and iteration on PR builds
   - Help them find the built image and validate with the conforma skill

3. **Downstream path**: Walk through the RHDS workflow from the guide:
   - Help them PR their hermetic changes to the component repo
   - Help them set up or update the pull request PipelineRun — if they need to create one from scratch, point them to the create-pr-pipeline skill
   - Guide them through triggering a PR build and checking results
   - Remind them about the FIPS check gate — do not suggest bypassing it

4. **Sync back to konflux-central**: After changes are verified, remind the user to sync PipelineRun changes back to the relevant konflux-central repo (ODH or RHDS, depending on the path taken). Walk through which files need updating (main branch PR pipeline, release branch push pipeline).

5. **Verify production builds**: Help them confirm that release branch builds are running correctly with the new config.

---
name: beaker-vm
description: Provision a VM on Red Hat Beaker for multi-arch testing
version: 1.0.0
---

# Provision a Beaker VM

Read `guides/beaker-vm.md` (relative to the plugin root) thoroughly before starting. It is the source of truth for all Beaker details — do not duplicate its content, reference it as you go.

> **Note:** This skill is specific to the internal Red Hat Beaker system and requires Red Hat Kerberos credentials and VPN access. Confirm the user has these before proceeding.

## Steps

1. **Determine requirements**: Ask the user what architecture they need (x86_64, aarch64, ppc64le, s390x) and what they plan to use the machine for. Ask if they have a distro preference (default to RHEL 9).

2. **Check prerequisites**: Confirm the user has Kerberos credentials and VPN access. Check if they have the `bkr` CLI configured — if not, walk them through the "Setup" section in the guide for their platform.

3. **Provision the machine**: Follow the "Provision a machine" section in the guide. Always start with `--dry-run --pretty-xml` so the user can review before submitting. Ask if they need packages pre-installed (e.g., `git`, `podman`, `rsync`) and use `--ks-append` if so. Ask about memory or disk requirements if relevant.

4. **Monitor and connect**: Follow the "Monitoring your job" section in the guide. Help the user watch the job and retrieve the hostname once provisioned.

5. **Next steps**: If the user is provisioning for hermetic build testing, point them to the [Testing on Remote Architectures](guides/hermeto-prefetch.md#testing-on-remote-architectures) section in the hermeto guide.

# Provisioning a VM on Beaker for Multi-Arch Testing

## What is Beaker

[Beaker](https://beaker.engineering.redhat.com/) is Red Hat's hardware provisioning system. It lets you reserve physical and virtual machines across architectures (x86_64, aarch64, ppc64le, s390x) for testing. This is useful when you need to validate builds on architectures you don't have locally -- especially ppc64le and s390x, which are difficult to obtain otherwise.

Once you have a machine provisioned, you can use it as a remote build host for hermetic build testing. See [Testing on Remote Architectures](hermeto-prefetch.md#testing-on-remote-architectures) in the hermeto guide for how to sync your project and run builds remotely.

## Prerequisites

- Red Hat Kerberos credentials
- Access to the Red Hat VPN

## Reserving a Machine

1. Go to the [Beaker reserve workflow](https://beaker.engineering.redhat.com/reserveworkflow/) and log in with your Kerberos credentials.

2. Select a distro family and distro tree for your target architecture. For example, select **RedHatEnterpriseLinux9** and pick the BaseOS tree for ppc64le or s390x:

   ![Distro and architecture selection](media/beaker-vm/distro-selection.png)

3. Set the reservation time based on your needs:

   ![Reservation time setting](media/beaker-vm/reservation-time.png)

4. Choose a system. You can select "Any system", pick a lab, or click **Select** next to "Specific system" to browse available machines:

   ![System selection options](media/beaker-vm/system-selection.png)

   The system search shows available machines with their architecture, vendor, and a **Reserve Now** button. Use **Show Search Options** to filter by hardware requirements:

   ![Reserve systems search with hardware details](media/beaker-vm/reserve-systems.png)

5. Click **Submit job** and wait for your recipe to finish provisioning.

6. Once provisioned, SSH into the machine as root. The default root password is shown in your [Beaker preferences](https://beaker.engineering.redhat.com/prefs/#root-password). You can also configure your SSH key in preferences for future reservations.

## Setting Up the Machine

Install the minimum dependencies needed for building:

```bash
dnf install -y git podman rsync
```

From here, follow the [Testing on Remote Architectures](hermeto-prefetch.md#testing-on-remote-architectures) section in the hermeto guide to sync your project from your local machine and run the hermetic build on the Beaker host.

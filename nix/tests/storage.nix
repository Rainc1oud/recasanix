# T3 — storage module: a diskless or blank-disk machine boots with nothing failed, a pool created at
# runtime (single or mirror) is picked up by convention and survives a reboot, and a mirror stays
# readable when a member device disappears. Pool creation is imperative on purpose (hot state).
{ pkgs }:
let
  node = {
    imports = [
      ../modules/appliance.nix
      ../modules/storage.nix
    ];
    # The appliance module insists on a way to log in; the test never uses it.
    recasanix.appliance.admin.initialHashedPassword = "!";
    virtualisation.emptyDiskImages = [
      512
      512
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "recasanix-storage";

  nodes = {
    # No data disks at all.
    diskless = {
      imports = [ node ];
      virtualisation.emptyDiskImages = pkgs.lib.mkForce [ ];
    };
    # Two blank disks and no pool yet: boot must not fail and must not touch the disks.
    blank = node;
    single = node;
    mirror = node;
  };

  testScript = ''
    start_all()

    # `mountpoint` is true for the not-yet-triggered automount too; ask for a real btrfs mount.
    BTRFS_MOUNTED = "findmnt -M /var/lib/recasanix/data -t btrfs"

    def assert_clean_boot(m):
        m.wait_for_unit("multi-user.target")
        m.succeed("systemctl is-system-running --wait | grep -qx running")
        m.fail(BTRFS_MOUNTED)
        m.fail("systemctl is-failed --quiet smartd.service")

    with subtest("diskless machine boots clean"):
        assert_clean_boot(diskless)

    with subtest("blank disks: boot is clean and does not destroy them"):
        assert_clean_boot(blank)
        # untouched: no filesystem signature was written
        blank.fail("blkid /dev/vdb")
        blank.fail("blkid /dev/vdc")
        # without a pool the mountpoint is unusable instead of silently filling the root device
        blank.fail("touch /var/lib/recasanix/data/oops")
        blank.fail(BTRFS_MOUNTED)

    with subtest("single pool: created at runtime, picked up by label, survives a reboot"):
        single.wait_for_unit("multi-user.target")
        single.succeed("mkfs.btrfs -q -L recasanix-data /dev/vdb")
        single.succeed("udevadm settle")
        single.succeed("echo persisted > /var/lib/recasanix/data/marker && sync")  # first access mounts
        single.succeed(BTRFS_MOUNTED)
        single.shutdown()
        single.start()
        single.wait_for_unit("multi-user.target")
        single.succeed("grep -qx persisted /var/lib/recasanix/data/marker")
        single.succeed(BTRFS_MOUNTED)
        single.succeed("btrfs filesystem df /var/lib/recasanix/data | grep -q 'Data, single'")

    with subtest("mirror pool: RAID1, readable after losing a device"):
        mirror.wait_for_unit("multi-user.target")
        mirror.succeed("mkfs.btrfs -q -L recasanix-data -d raid1 -m raid1 /dev/vdb /dev/vdc")
        mirror.succeed("udevadm settle")
        mirror.succeed("dd if=/dev/urandom of=/var/lib/recasanix/data/blob bs=1M count=32 && sync")
        df = mirror.succeed("btrfs filesystem df /var/lib/recasanix/data")
        assert "Data, RAID1" in df and "Metadata, RAID1" in df, df
        mirror.succeed("sha256sum /var/lib/recasanix/data/blob > /tmp/blob.sum")

        # pull one member device out from under the running pool
        # (virtio-blk has no SCSI-style `device/delete`; remove its PCI function instead)
        mirror.succeed("echo 1 > $(readlink -f /sys/block/vdc/device/..)/remove")
        mirror.succeed("! test -e /sys/block/vdc")
        mirror.succeed("sha256sum -c /tmp/blob.sum")
        mirror.succeed("echo more > /var/lib/recasanix/data/after && sync")
        mirror.wait_until_succeeds("journalctl -k --no-pager | grep -Ei 'btrfs.*(missing|error|degraded|failed)'")
  '';
}

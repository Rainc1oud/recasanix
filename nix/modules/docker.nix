# Task 3.3 — the container runtime behind the app store.
#
# Docker, cold layer: enablement, storage driver and data root are declared here (the API that used to
# rewrite /etc/docker/daemon.json is not routed, see the register). Podman is a later evaluation
# (AGENTS.md §2): re-test app-store compatibility against `virtualisation.podman.dockerCompat`.
#
# ReCasaOS' app management needs no Docker CLI or compose plugin at runtime: it embeds the compose
# library and talks to the daemon's socket, so nothing here is put on its unit's PATH. The `docker` CLI is
# installed for operators.
{ config, lib, ... }:
let
  cfg = config.recasanix.docker;
  storage = config.recasanix.storage;
  poolDevice = "/dev/disk/by-label/${storage.poolLabel}";
  dataRoot = "${storage.mountPoint}/docker";
in
{
  options.recasanix.docker.enable = lib.mkEnableOption "Docker with its data root on the data pool";

  config = lib.mkIf cfg.enable {
    virtualisation.docker = {
      enable = true;
      # overlay2 also works on btrfs, which is what the pool is; avoids the btrfs driver's subvolume sprawl.
      storageDriver = "overlay2";
      # App images and layers must not fill the small eMMC: the data root lives on the pool.
      daemon.settings.data-root = dataRoot;
    };

    # No pool, no containers — and no failure: the appliance must boot clean (and show its UI, where the
    # pool gets created) without one. The condition skips the unit instead of failing it; when the pool
    # is created at runtime, the storage layer starts docker.service. With the pool present, it is
    # mounted first and docker follows.
    systemd.services.docker.unitConfig = {
      ConditionPathExists = poolDevice;
      RequiresMountsFor = storage.mountPoint;
    };
  };
}

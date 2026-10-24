# Modules of the image (CasaOS-Install release/modules.env, pinned like the components, nix/lib/components.nix):
# built into the image, listed in the core's module catalogue (`services.recasaos.imageModules`), enabled per
# box from the Modules page — the core's image provider writes /var/lib/casaos/modules/<name>.enabled and
# starts the unit; each unit starts at boot only where that flag exists. Their Debian package lists
# (module.json `packages`) are not used: the nixpkgs equivalents are set here.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.recasaos;
  virt = cfg.modules.virt;
  flag = name: "/var/lib/casaos/modules/${name}.enabled";
  rootMounts = map (r: "${utils.escapeSystemdPath r}.mount") cfg.fileRoots;
  virtPkg = pkgs.casaos-virt-management;

  # QEMU for this host's CPU, headless: the module's consoles are VNC (kept) through the dashboard; no
  # GTK/SDL/SPICE/audio/braille (≈1 GiB of desktop libraries otherwise). OVMF firmware (blobs) kept;
  # libusb added for USB passthrough (usb-host; upstream's build gets it only through SPICE's usbredir).
  qemu =
    (pkgs.qemu_kvm.override {
      gtkSupport = false;
      sdlSupport = false;
      spiceSupport = false;
      pulseSupport = false;
      pipewireSupport = false;
      jackSupport = false;
      alsaSupport = false;
      smartcardSupport = false;
      ncursesSupport = false;
      brlttySupport = false;
      libiscsiSupport = false;
      capstoneSupport = false;
      guestAgentSupport = false;
      enableDocs = false;
    }).overrideAttrs
      (old: {
        buildInputs = old.buildInputs ++ [ pkgs.libusb1 ];
        # host-CPU-only QEMU runs guests of this architecture: the UEFI firmware of the others (≈280 MiB of
        # edk2 images for ARM, RISC-V, LoongArch) and their descriptors go
        postInstall =
          (old.postInstall or "")
          + lib.optionalString pkgs.stdenv.hostPlatform.isx86_64 ''
            rm -f $out/share/qemu/edk2-{arm,aarch64,riscv,loongarch64}-*.fd
            rm -f $out/share/qemu/firmware/60-edk2-{arm,aarch64,riscv64,loongarch64}.json
          '';
      });
  # no Xen driver (pulls Xen and Open vSwitch), no ZFS storage backend (pools are btrfs)
  libvirt = pkgs.libvirt.override {
    enableXen = false;
    enableZfs = false;
  };
in
{
  options.services.recasaos.modules.virt.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Ship the virtual-machines module (CasaOS-VirtManagement, pinned by the release's modules.env) in the
      image: libvirt (socket-activated), QEMU, its unit and its catalogue entry. Off until enabled on the
      Modules page.
    '';
  };

  config = lib.mkIf (cfg.enable && virt.enable) {
    services.recasaos.imageModules = [ virtPkg.catalogueEntry ];

    # module.json packages: qemu-utils, qemu-system-x86/-arm, ovmf/qemu-efi-aarch64 (OVMF ships with
    # QEMU on NixOS), libvirt-daemon-system, libvirt-clients, dnsmasq-base (libvirtd's own path)
    virtualisation.libvirtd = {
      enable = true;
      package = libvirt;
      qemu.package = qemu;
    };
    systemd.services = {
      # cloud-hypervisor's libvirt driver daemon: not used (QEMU only)
      virtchd.enable = false;
      # socket-activated, exits after 120 s idle: runs while the module uses it, not on every box
      libvirtd.wantedBy = lib.mkForce [ ];
      # starts and stops the guests around a boot (onBoot/onShutdown): started by the module's unit once
      # it runs (below); not at boot, its Wants= on libvirtd would start libvirtd on every box
      libvirt-guests.wantedBy = lib.mkForce [ ];

      casaos-virt-management = {
        description = "CasaOS Virtual Machine Management Service";
        wantedBy = [ "multi-user.target" ];
        # upstream: After gateway, bus, libvirtd; Wants libvirtd — dropped: systemd queues the Wants= of a
        # unit whose condition fails too, so libvirtd would start on every box. libvirtd is socket-activated
        # by the module's connection; libvirt-guests is started below once the module runs.
        after = [
          "network.target"
          "recasanix-state-init.service"
          "casaos-gateway.service"
          "casaos-message-bus.service"
          "libvirtd.service"
        ]
        ++ rootMounts;
        requires = [ "recasanix-state-init.service" ];
        # enabled on this box (the core's image provider writes the flag)
        unitConfig.ConditionPathExists = flag virtPkg.catalogueEntry.name;
        # qemu-img: disk images; iptables, iptables-restore: the chains of the VM network (CASAOS-VM*)
        path = [
          qemu
          pkgs.iptables
        ];
        # HOT config, seeded once from upstream's sample (as the components' in recasanix-state-init)
        preStart = ''
          [ -e /etc/casaos/virt-management.conf ] ||
            install -m 0600 ${virtPkg}/share/casaos-sysroot/etc/casaos/virt-management.conf.sample /etc/casaos/virt-management.conf
        '';
        serviceConfig = {
          Type = "notify";
          Restart = "always";
          ExecStart = "${lib.getExe virtPkg} -c /etc/casaos/virt-management.conf";
          # the guests' start at boot and their shutdown with the host, where the module runs
          ExecStartPost = "${pkgs.systemd}/bin/systemctl start --no-block libvirt-guests.service";
        };
      };
    };
  };
}

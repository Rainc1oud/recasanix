# `nix run .#vm` — the runVM script of `nixosConfigurations.recasanix-vm` with stable disk locations and a
# short banner. Two disks persist across runs: the root disk (reset when the VM definition changes — it
# carries the installed generation) and the *state* disk (accounts, ReCasaOS data, SSH host keys — kept
# across VM rebuilds, exactly like the `state` partition of the hardware image). The blank data disk
# is recreated on every run. The firmware's variable store (NIX_EFI_VARS) is pinned here too: left unset,
# NixOS's own script defaults it to "recasanix-efi-vars.fd" in whatever directory the VM happens to be
# started from, which is how one ended up committed to the repo root.
#
# The disks live in a directory per checkout (keyed by the git top-level of the current directory), so
# two clones never boot each other's disks. `--fresh` resets the root disk by hand; a damaged root
# filesystem is also repaired automatically at boot (fsck.repair=yes, nix/modules/vm.nix).
{
  lib,
  writeShellApplication,
  qemu_kvm,
  git,
  coreutils,
  vm, # nixosConfigurations.recasanix-vm.config.system.build.vm
}:
writeShellApplication {
  name = "recasanix-vm";
  runtimeInputs = [
    qemu_kvm
    git
    coreutils
  ];
  text = ''
    fresh=
    if [ "''${1:-}" = --fresh ]; then
      fresh=1
      shift
    fi

    # One disk directory per checkout: the same VM definition built from two clones must not share disks.
    checkout=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    key="$(basename "$checkout")-$(printf %s "$checkout" | sha256sum | cut -c1-12)"
    state="''${RECASANIX_VM_DIR:-''${XDG_STATE_HOME:-$HOME/.local/state}/recasanix-vm/$key}"
    mkdir -p "$state"
    export NIX_DISK_IMAGE="''${NIX_DISK_IMAGE:-$state/recasanix.qcow2}"
    export RECASANIX_STATE_IMAGE="''${RECASANIX_STATE_IMAGE:-$state/recasanix-state.qcow2}"
    export NIX_EFI_VARS="''${NIX_EFI_VARS:-$state/recasanix-efi-vars.fd}"

    # The root disk carries the installed system generation, so a rebuilt VM would otherwise keep
    # booting the old one: start it fresh whenever the VM definition changes. Hot state is not lost —
    # it lives on the separate state disk.
    if [ -n "$fresh" ] || [ "$(cat "$state/vm-definition" 2>/dev/null || true)" != "${vm}" ]; then
      rm -f "$NIX_DISK_IMAGE"
      echo "${vm}" >"$state/vm-definition"
    fi
    [ -e "$RECASANIX_STATE_IMAGE" ] || qemu-img create -q -f qcow2 "$RECASANIX_STATE_IMAGE" 2G

    # Note: the UEFI firmware clears the terminal a moment after this, so this banner is only really
    # readable in a log. The same hints are in the VM's login MOTD (nix/modules/vm.nix) and TESTING.md.
    cat >&2 <<EOF
    ReCasaNix VM — serial console on this terminal (quit QEMU: Ctrl-A x)
      web UI    http://localhost:8080
      ssh       ssh -p 2222 admin@localhost     (development password: recasanix)
      first run recasanix-user-admin bootstrap   (inside the VM: creates the UI administrator)
      data disk /dev/vdb, blank. Apps need a pool (until the storage layer exists, by hand, as root):
                 mkfs.btrfs -L recasanix-data /dev/vdb
                 mkdir -p /var/lib/recasanix/data/DATA
                 systemctl start DATA.mount docker; systemctl restart casaos casaos-app-management
      root disk  $NIX_DISK_IMAGE  (reset when the VM is rebuilt, or with --fresh)
      state disk $RECASANIX_STATE_IMAGE  (accounts, ReCasaOS data; delete it for a factory-fresh VM)
      efi vars   $NIX_EFI_VARS
    EOF
    exec ${lib.getExe' vm "run-recasanix-vm"} "$@"
  '';
}

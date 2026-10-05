# `nix run .#emulate-image` — boot `packages.image` under QEMU as it would be flashed: UEFI (OVMF), an
# NVMe disk and an Intel NIC, nothing added for testing (the check that does the same unattended is T6,
# `image-boots`). Unlike `nix run .#vm`, which is the development VM, this runs the real artifact.
#
# The image in the Nix store is read-only, so it is copied to a scratch disk first (sparse: only the
# ~2.6 GiB that are actually written) and enlarged, like flashing it to a bigger eMMC — the data
# partition grows to fill it on first boot. The disk is kept between runs, so hot state persists, and is
# recreated when the image changes or with `--fresh`.
#
# A blank SATA data disk is attached as well (a sparse backing file next to the system disk), like the
# board's data slots: the image has no pool, and creating one needs a disk to put it on. It persists
# like the system disk, so a pool made on it survives runs (RECASANIX_DATA_DISKS=2 adds a second, e.g. to try a mirror).
{
  lib,
  writeShellApplication,
  qemu_kvm,
  coreutils,
  OVMF,
  image, # nixosConfigurations.recasanix-image.config.system.build.image
  sshKeys, # how many keys nix/hosts/admin-authorized-keys held when the image was built
}:
writeShellApplication {
  name = "recasanix-emulate-image";
  runtimeInputs = [
    qemu_kvm
    coreutils
  ];
  text = ''
    usage() {
      cat <<'EOF'
    Usage: recasanix-emulate-image [--fresh] [-- <extra qemu arguments>]

    Boots the image for the custom NAS under QEMU/OVMF (serial console on this terminal;
    quit with Ctrl-A x). The image is copied to a scratch disk first.

      --fresh    discard the scratch disk (and the data disks) and start from the pristine image

    Environment (defaults in brackets):
      RECASANIX_IMAGE_DIR      where the scratch disk lives                       [/tmp/recasanix-image]
      RECASANIX_DISK_SIZE      size of the emulated disk, e.g. 32G or 64G         [32G]
      RECASANIX_DATA_DISKS     number of blank SATA data disks (0-6)              [1]
      RECASANIX_DATA_DISK_SIZE size of each data disk                             [8G]
      RECASANIX_HEADROOM_GIB   free space required beyond the copy itself, in GiB [4]
      RECASANIX_UI_PORT        host port forwarded to the web UI (guest 80)       [8081]
      RECASANIX_SSH_PORT       host port forwarded to SSH (guest 22)              [2223]
      RECASANIX_BIND           host address the forwards listen on                [127.0.0.1]
      RECASANIX_MEM_MB         guest memory in MiB                                [4096]
      RECASANIX_CPUS           guest CPUs                                         [2]
    EOF
    }

    die() { echo "recasanix-emulate-image: $*" >&2; exit 1; }

    fresh=
    qemu_extra=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --fresh) fresh=1 ;;
        -h | --help) usage; exit 0 ;;
        --) shift; qemu_extra=("$@"); break ;;
        *) usage >&2; die "unknown argument: $1" ;;
      esac
      shift
    done

    dir=''${RECASANIX_IMAGE_DIR:-/tmp/recasanix-image}
    disk_size=''${RECASANIX_DISK_SIZE:-32G}
    data_disks=''${RECASANIX_DATA_DISKS:-1}
    data_size=''${RECASANIX_DATA_DISK_SIZE:-8G}
    headroom_gib=''${RECASANIX_HEADROOM_GIB:-4}
    ui_port=''${RECASANIX_UI_PORT:-8081}
    ssh_port=''${RECASANIX_SSH_PORT:-2223}
    bind=''${RECASANIX_BIND:-127.0.0.1}
    mem=''${RECASANIX_MEM_MB:-4096}
    cpus=''${RECASANIX_CPUS:-2}

    [ -r /dev/kvm ] && [ -w /dev/kvm ] || die "/dev/kvm is not accessible: this needs KVM (add yourself to the kvm group)"

    case "$data_disks" in [0-6]) ;; *) die "RECASANIX_DATA_DISKS=$data_disks must be 0-6 (the emulated SATA controller has six ports)" ;; esac
    numfmt --from=iec "$data_size" > /dev/null || die "RECASANIX_DATA_DISK_SIZE=$data_size is not a size (try 8G)"

    image_dir=${image}
    shopt -s nullglob
    images=("$image_dir"/*.raw)
    [ ''${#images[@]} -eq 1 ] || die "expected exactly one .raw in $image_dir, found ''${#images[@]}"
    src=''${images[0]}

    disk="$dir/disk.raw"
    vars="$dir/OVMF_VARS.fd"
    stamp="$dir/image-path"

    # A scratch disk is only reusable if it was made from this very image.
    if [ -z "$fresh" ] && [ -e "$disk" ] && [ -e "$vars" ] && [ "$(cat "$stamp" 2>/dev/null || true)" = "$image_dir" ]; then
      new=
    else
      new=1
    fi

    if [ -n "$new" ]; then
      want=$(numfmt --from=iec "$disk_size") || die "RECASANIX_DISK_SIZE=$disk_size is not a size (try 32G)"
      have=$(stat -L -c %s "$src")
      [ "$want" -ge "$have" ] || die "RECASANIX_DISK_SIZE=$disk_size is smaller than the image ($(numfmt --to=iec "$have"))"
    fi

    # Free space. The disk is sparse, so what it costs now is what the image really occupies (not the
    # 22 GiB it looks like); the headroom is for the guest to write into. A full filesystem shows up in
    # the guest as I/O errors, so refuse to start rather than fail halfway through a boot.
    mkdir -p "$dir"
    need=$(( headroom_gib * 1024 * 1024 * 1024 ))
    if [ -n "$new" ]; then
      need=$(( need + $(du -L -B1 "$src" | cut -f1) ))
      # a disk about to be replaced gives its space back
      if [ -e "$disk" ]; then
        reclaim=$(du -B1 "$disk" | cut -f1)
        need=$(( need > reclaim ? need - reclaim : 0 ))
      fi
    fi
    avail=$(df -B1 --output=avail "$dir" | tail -n1 | tr -d ' ')
    fstype=$(df --output=fstype "$dir" | tail -n1 | tr -d ' ')
    if [ "$avail" -lt "$need" ]; then
      die "not enough free space in $dir: $(numfmt --to=iec "$need") needed, $(numfmt --to=iec "$avail") available ($fstype).
    Set RECASANIX_IMAGE_DIR to a larger filesystem, or lower RECASANIX_HEADROOM_GIB (now $headroom_gib)."
    fi
    if [ "$fstype" = tmpfs ]; then
      echo "note: $dir is a tmpfs, so the disk lives in RAM; set RECASANIX_IMAGE_DIR to keep it on disk." >&2
    fi

    if [ -n "$new" ]; then
      echo "copying the image to $disk (sparse, $(numfmt --to=iec "$(du -L -B1 "$src" | cut -f1)") on disk) ..." >&2
      rm -f "$disk" "$vars" "$stamp" "$disk.tmp"
      cp --sparse=always "$src" "$disk.tmp"
      chmod u+w "$disk.tmp"
      truncate -s "$disk_size" "$disk.tmp"
      mv "$disk.tmp" "$disk"
      # The firmware's variable store (NVRAM: boot entries, boot order, ...) is written by the firmware
      # itself, so it cannot be used from the read-only store. It could be made to run from there
      # (readonly=on or snapshot=on both boot), but then it would not persist along with the disk. It
      # belongs to the machine like the disk does, and the update phase will depend on it: slot
      # switching goes through EFI variables.
      cp ${OVMF.fd}/FV/OVMF_VARS.fd "$vars"
      chmod u+w "$vars"
      # a fresh start means fresh data disks too: they may hold a pool from the previous image
      rm -f "$dir"/data*.raw
      echo "$image_dir" > "$stamp"
    fi

    for i in $(seq 1 "$data_disks"); do
      [ -e "$dir/data$i.raw" ] || truncate -s "$data_size" "$dir/data$i.raw"
    done

    # Note: the UEFI firmware clears the terminal a moment after this, so this banner is only really
    # readable in a log (see TESTING.md, and the build-time warning about missing SSH keys).
    cat >&2 <<EOF
    ReCasaNix image under QEMU/OVMF — serial console on this terminal (quit QEMU: Ctrl-A x)
      web UI    http://$bind:$ui_port
      ssh       ssh -p $ssh_port admin@$bind
      disk      $disk  ($disk_size, kept between runs; --fresh starts over)
      data      $data_disks blank SATA disk(s) of $data_size: /dev/disk/by-id/ata-QEMU_HARDDISK_recasanix-data1, ...
    EOF
    ${
      if sshKeys == 0 then
        ''
          cat >&2 <<'EOF'
            NOTE: the image was built without SSH keys, so there is no way to log in. Put your public key in
            nix/hosts/admin-authorized-keys (working copy only, never commit it) and rebuild (see docs/flashing.md).
          EOF
        ''
      else
        ''
          echo "  login     key-only, as admin (${toString sshKeys} authorized key(s) built in); then: sudo recasanix-user-admin bootstrap" >&2
        ''
    }
    data_args=()
    for i in $(seq 1 "$data_disks"); do
      data_args+=(-drive "if=none,id=data$i,format=raw,file=$dir/data$i.raw" -device "ide-hd,drive=data$i,bus=ide.$((i - 1)),serial=recasanix-data$i")
    done

    exec qemu-system-x86_64 \
      -machine q35,accel=kvm -cpu host -smp "$cpus" -m "$mem" -nographic \
      -drive if=pflash,format=raw,unit=0,readonly=on,file=${OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,unit=1,file="$vars" \
      -drive if=none,id=disk,format=raw,file="$disk" \
      -device nvme,drive=disk,serial=recasanix0,bootindex=1 \
      -netdev "user,id=net0,hostfwd=tcp:$bind:$ui_port-:80,hostfwd=tcp:$bind:$ssh_port-:22" \
      -device e1000e,netdev=net0 \
      "''${data_args[@]}" \
      "''${qemu_extra[@]}"
  '';

  meta = {
    description = "Boot the custom developed NAS image under QEMU/OVMF, on a scratch copy";
    mainProgram = "recasanix-emulate-image";
    platforms = lib.platforms.linux;
  };
}

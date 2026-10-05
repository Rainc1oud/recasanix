# T6 — boot the real image artifact.
#
# `packages.image` is booted as it would be flashed: under OVMF, from an NVMe disk with an Intel NIC —
# the board's kind of hardware, not virtio — with nothing added for testing. That is why this is a plain
# QEMU run and not a `runNixOSTest`: the NixOS test driver needs a backdoor service inside the guest,
# which would make it a different system from the one that ships. What it can see is therefore only
# what a user sees: the serial console, the web UI, and the disk afterwards.
#
# It catches what a `nixos-rebuild`-style VM test cannot: a wrong partition layout, a boot loader the
# firmware does not find, a root that the initrd cannot name, hot state that does not land on its
# partition, and the first-boot growth of the data partition.
{ pkgs, image }:
let
  efiSystem = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B";
  rootX86_64 = "4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709";
  linuxGeneric = "0FC63DAF-8483-4772-8E79-3D69D8477DE4";
  dataType = "BA64870A-584F-406F-B37A-AC7CDA39B97E"; # nix/modules/image.nix
  rootBUuid = "2C7BB7DB-C0B6-4C5E-81C1-56D2F9596B21";
in
pkgs.runCommand "image-boots"
  {
    nativeBuildInputs = with pkgs; [
      qemu_kvm
      netcat-openbsd
      curl
      jq
      util-linux # sfdisk
      e2fsprogs # debugfs
    ];
    requiredSystemFeatures = [ "kvm" ];
    meta.description = "Boots packages.image under OVMF and checks layout, first-boot growth and hot state";
  }
  ''
    set -euo pipefail
    cd "$TMPDIR"

    fail() { echo "FAIL: $*" >&2; exit 1; }
    dump() { echo "----- serial console -----"; cat serial.log 2>/dev/null || true; }
    trap 'kill "$qemu" 2>/dev/null || true' EXIT

    images=(${image}/*.raw)
    [ ''${#images[@]} -eq 1 ] || fail "expected exactly one .raw in ${image}, got: ''${images[*]}"

    # The disk the image is "flashed" to is larger than the image: 32 GiB. Only the file is grown, so
    # the partition table still ends where the image did — like any image dd'ed to a bigger eMMC.
    cp --sparse=always "''${images[0]}" disk.raw
    chmod +w disk.raw
    truncate -s 32G disk.raw
    cp ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars.fd
    chmod +w vars.fd

    qemu-system-x86_64 \
      -machine q35,accel=kvm -cpu host -smp 2 -m 4096 -display none \
      -drive if=pflash,format=raw,unit=0,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,unit=1,file=vars.fd \
      -drive if=none,id=disk,format=raw,file=disk.raw \
      -device nvme,drive=disk,serial=recasanix0,bootindex=1 \
      -netdev user,id=net0,hostfwd=tcp:127.0.0.1:18080-:80 \
      -device e1000e,netdev=net0 \
      -serial file:serial.log \
      -monitor unix:monitor.sock,server,nowait &
    qemu=$!

    echo "waiting for the web UI (up to 5 minutes)..."
    up=
    for _ in $(seq 1 150); do
      kill -0 "$qemu" 2>/dev/null || { dump; fail "QEMU exited before the UI came up"; }
      if curl -fsS -m 3 http://127.0.0.1:18080/ 2>/dev/null | grep -qi '<html'; then up=1; break; fi
      sleep 2
    done
    [ -n "$up" ] || { dump; fail "the web UI did not come up on the flashed image"; }

    grep -q 'recasanix login:' serial.log || { dump; fail "no login prompt on the serial console"; }

    # A clean shutdown, so the state filesystem is consistent when it is read below.
    echo system_powerdown | nc -U -N monitor.sock >/dev/null || true
    for _ in $(seq 1 60); do kill -0 "$qemu" 2>/dev/null || break; sleep 1; done
    kill -0 "$qemu" 2>/dev/null && fail "the guest did not power off when asked"
    wait "$qemu" || true

    sfdisk -J disk.raw > table.json
    jq . table.json

    part() { jq -c --arg n "$1" '.partitiontable.partitions[] | select(.name == $n)' table.json; }
    field() { part "$1" | jq -r ".$2"; }

    # --- layout: exactly five partitions, of the intended types and sizes -------------------------
    [ "$(jq '.partitiontable.partitions | length' table.json)" -eq 5 ] || fail "expected 5 partitions"
    [ "$(jq -r '.partitiontable.label' table.json)" = gpt ] || fail "not a GPT disk"

    expect() { # name type size-in-MiB
      [ "$(field "$1" type | tr a-z A-Z)" = "$2" ] || fail "$1 has type $(field "$1" type), expected $2"
      [ "$(( $(field "$1" size) * 512 / 1048576 ))" -eq "$3" ] || fail "$1 is $(( $(field "$1" size) * 512 / 1048576 )) MiB, expected $3"
    }
    expect recasa-esp        ${efiSystem}   512
    expect recasanix-root-a  ${rootX86_64}  8192
    expect recasanix-root-b  ${rootX86_64}  8192
    expect recasanix-state   ${linuxGeneric} 4096
    [ "$(field recasanix-root-b uuid | tr a-z A-Z)" = ${rootBUuid} ] || fail "root-b lost its stable UUID"

    # --- first-boot growth: the data partition now fills the 32 GiB disk --------------------------
    [ "$(field recasanix-data type | tr a-z A-Z)" = ${dataType} ] || fail "recasanix-data has the wrong type"
    data_mib=$(( $(field recasanix-data size) * 512 / 1048576 ))
    echo "recasanix-data is $data_mib MiB (image built it at 512 MiB)"
    [ "$data_mib" -gt 10000 ] || fail "the data partition did not grow ($data_mib MiB)"

    # --- root-b is still empty: nothing has written to the slot reserved for the update -----------
    start=$(( $(field recasanix-root-b start) * 512 )); bytes=$(( $(field recasanix-root-b size) * 512 ))
    dd if=disk.raw iflag=skip_bytes,count_bytes skip=$start count=$bytes bs=1M status=none \
      | cmp -n "$bytes" - /dev/zero || fail "recasanix-root-b is not empty"

    # --- hot state landed on its own partition, not on the root filesystem ------------------------
    start=$(( $(field recasanix-state start) * 512 )); bytes=$(( $(field recasanix-state size) * 512 ))
    dd if=disk.raw of=state.img iflag=skip_bytes,count_bytes skip=$start count=$bytes bs=1M conv=sparse status=none
    debugfs -R 'stat /ssh/ssh_host_ed25519_key' state.img 2>&1 | grep -q 'Type: regular' \
      || fail "the SSH host key is not on the state partition"
    debugfs -R 'stat /accounts/passwd' state.img 2>&1 | grep -q 'Type: regular' \
      || fail "the account database was not mirrored to the state partition"

    summary="image boots: 5 partitions, data grown to $data_mib MiB, root-b empty, hot state on its partition"
    echo "$summary"

    # A passing run leaves its evidence, not an empty file: the console of the boot that was checked
    # and the partition table as the guest left it.
    mkdir -p "$out"
    echo "$summary" > "$out/summary.txt"
    cp serial.log "$out/serial.log"
    cp table.json "$out/partition-table.json"
  ''

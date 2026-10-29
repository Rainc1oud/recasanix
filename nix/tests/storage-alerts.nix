# T17 — RAID alerts for the btrfs pool, end to end: the root's alert hub (fork branch
# feat/raid-alerts-any-backend, in staging) asks recasanix-storage for GET /v1/disks/raid through the
# gateway's route table, with the internal secret (reads only), and sends to a channel.
# - mirror, a member unplugged → "degraded" alert (first RAID poll, 5 min after casaos starts)
# - more writes → the member's error counters grow → "new errors" alert (next poll, 5 min later)
# Slow by design: the hub's timers are upstream's (5 min), not shortened for the test.
{ pkgs, modules }:
let
  # the channel: a webhook on loopback, every body appended to /tmp/hook.log
  hook = pkgs.writeText "hook.py" ''
    import http.server

    class Hook(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            with open("/tmp/hook.log", "ab") as f:
                f.write(body + b"\n---\n")
            self.send_response(200)
            self.end_headers()

    http.server.HTTPServer(("127.0.0.1", 9099), Hook).serve_forever()
  '';
  alerts = pkgs.writeText "alerts.json" (
    builtins.toJSON {
      channels = [
        {
          id = "hook";
          name = "test hook";
          url = "generic://127.0.0.1:9099/hook?disabletls=yes";
        }
      ];
      categories = { };
      disk_threshold = 90;
    }
  );
in
pkgs.testers.runNixOSTest {
  name = "recasanix-storage-alerts";

  nodes.machine = {
    imports = [
      modules.appliance
      modules.storage
      modules.docker
      modules.recasaos
    ];
    services.recasaos.enable = true;
    recasanix.docker.enable = true;
    recasanix.appliance.admin.initialHashedPassword = "!";
    virtualisation.memorySize = 2048;
    virtualisation.emptyDiskImages = [
      2048
      2048
    ];
    environment.systemPackages = [ pkgs.jq ];
    systemd.services.test-hook = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${hook}";
    };
  };

  testScript = ''
    machine.start()
    for unit in ["casaos-gateway.service", "recasanix-storage.service", "test-hook.service"]:
        machine.wait_for_unit(unit)
    machine.wait_for_open_port(9099)

    # the pool as a mirror, by hand (TESTING.md), online the way the storage manager brings it up
    machine.succeed("mkfs.btrfs -q -f -L recasanix-data -d raid1 -m raid1 /dev/vdb /dev/vdc && udevadm settle")
    machine.succeed("mkdir -p /var/lib/recasanix/data/DATA && mountpoint -q /var/lib/recasanix/data")
    machine.succeed("systemctl start DATA.mount docker.service")

    # a channel, then a fresh start of the root service: its RAID poll comes 5 min later
    machine.succeed("install -m600 ${alerts} /var/lib/casaos/alerts.json")
    machine.succeed("systemctl restart casaos.service")
    machine.wait_for_unit("casaos.service")

    # the internal secret reads, and only reads
    secret = "$(cat /var/run/casaos/internal.secret)"
    target = "$(curl -s -H \"Authorization: Internal " + secret + "\" http://$(cat /var/run/casaos/management.url | sed 's|http://||')/v1/gateway/routes | jq -r '.[] | select(.path==\"/v1/disks\") | .target')"
    machine.succeed(f"curl -sf -H \"Authorization: Internal {secret}\" {target}/v1/disks/raid | jq -e '.data[0].level == \"raid1\"'")
    machine.succeed(f"curl -sf -H \"Authorization: Internal {secret}\" {target}/v1/disks | jq -e '[.data.disks[].smart_status] | all(. == \"unavailable\")'")
    code = machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' -X POST -H \"Authorization: Internal {secret}\" -d '{{\"path\":\"/dev/vdc\",\"format\":true}}' {target}/v1/storage").strip()
    assert code == "401", f"a write with the internal secret -> {code}"

    # a member unplugged while mounted, and writes that fail on it
    machine.succeed("echo 1 > $(readlink -f /sys/block/vdc/device/..)/remove")
    machine.succeed("dd if=/dev/urandom of=/var/lib/recasanix/data/a bs=1M count=20 conv=fsync")
    machine.wait_until_succeeds(
        "grep -q 'RAID recasanix-data (RAID1) is degraded: disk vdc has failed' /tmp/hook.log", timeout=420
    )
    assert "new read, write or checksum errors" not in machine.succeed("cat /tmp/hook.log"), \
        "the first poll only records the error counters"

    # more failed writes: the counters grow, the next poll tells
    machine.succeed("dd if=/dev/urandom of=/var/lib/recasanix/data/b bs=1M count=20 conv=fsync")
    machine.wait_until_succeeds(
        "grep -q 'Disk vdc of RAID recasanix-data (RAID1) reported .* new read, write or checksum errors' /tmp/hook.log",
        timeout=420,
    )
    print(machine.succeed("cat /tmp/hook.log"))
  '';
}

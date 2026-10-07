# T14 — share accounts and share access through the real web UI (headless Chromium), on top of the
# backend checked by smb-shares (T13). UI patches 0007–0008 (upstream PRs).
{ pkgs, modules }:
let
  python = pkgs.python3.withPackages (ps: [ ps.playwright ]);
  script = ./smb-ui.py;
  fonts = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
in
pkgs.testers.runNixOSTest {
  name = "recasanix-smb-ui";

  nodes.machine = {
    imports = [
      modules.appliance
      modules.storage
      modules.state
      modules.docker
      modules.recasaos
    ];
    services.recasaos.enable = true;
    recasanix = {
      docker.enable = true;
      state.enable = true;
      appliance.admin.initialHashedPassword = "!";
    };
    # a data pool, so Docker runs: without it app management answers the app grid with 500 and the
    # dashboard (upstream) drops the whole grid, the built-in Files app included
    virtualisation.emptyDiskImages = [ 2048 ];
    virtualisation.memorySize = 3072;
  };

  testScript = ''
    import json
    import os
    import subprocess

    machine.start()
    for unit in ["casaos.service", "casaos-user-service.service", "samba-smbd.service"]:
        machine.wait_for_unit(unit)
    machine.wait_for_open_port(80)
    pool = "/var/lib/recasanix/data"
    machine.succeed("mkfs.btrfs -q -L recasanix-data /dev/vdb && udevadm settle")
    machine.succeed(f"mkdir -p {pool}/DATA")
    machine.succeed("systemctl start DATA.mount docker.service")
    machine.succeed("systemctl restart casaos.service casaos-app-management.service")
    machine.wait_for_unit("casaos-app-management.service")
    machine.succeed("printf 'admin\\nrecasanix-admin-pass-1\\n' | recasanix-user-admin bootstrap")
    machine.wait_for_unit("casaos-user-service.service")
    machine.succeed("mkdir -p /DATA/Media")
    machine.forward_port(host_port=8090, guest_port=80)

    env = dict(
        os.environ,
        HOME="/tmp",
        PLAYWRIGHT_BROWSERS_PATH="${pkgs.playwright-driver.browsers}",
        PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS="true",
        FONTCONFIG_FILE="${fonts}",
    )
    result = subprocess.run(
        ["${python}/bin/python", "${script}", "http://localhost:8090", "admin", "recasanix-admin-pass-1", "carol", "carol-pass-1"],
        env=env, capture_output=True, text=True, timeout=600,
    )
    print(result.stdout)
    print(result.stderr[-3000:])
    assert result.returncode == 0, "share UI check failed (output above)"

    login = json.loads(machine.succeed(
        "curl -s -X POST -H 'Content-Type: application/json' "
        "-d '{\"username\":\"admin\",\"password\":\"recasanix-admin-pass-1\"}' http://localhost/v1/users/login"
    ))
    auth = "-H 'Authorization: Bearer " + login["data"]["token"]["access_token"] + "'"
    shares = json.loads(machine.succeed(f"curl -s {auth} http://localhost/v1/samba/shares"))["data"]
    assert [(s["path"], s["username"]) for s in shares] == [("/DATA/Media", "carol")], shares
    machine.succeed("test \"$(stat -c '%U %a' /DATA/Media)\" = 'carol 770'")
    machine.succeed("smbclient //localhost/Media -U carol%carol-pass-1 -m SMB3 -c ls")
  '';
}

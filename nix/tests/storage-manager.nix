# T11 — the storage manager (recasanix-storage), end to end behind the real gateway: the routes the UI
# calls answer with real data from the real lsblk, only for holders of a real access token; creating a
# storage on a blank disk actually works (through the real UI, once, and through the API for a second
# disk to exercise the JBOD-extend branch); everything else that would change an existing storage is
# refused with a message that says why. Also: it finds its way back after the gateway restarts, and it
# never touches a disk it was not explicitly, validly asked to use.
{ pkgs, modules }:
let
  python = pkgs.python3.withPackages (ps: [ ps.playwright ]);
  panelScript = ./storage-panel.py;
  fonts = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
in
pkgs.testers.runNixOSTest {
  name = "recasanix-storage-manager";

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
    # Two blank disks: /dev/vdb and /dev/vdc, above the 1 GiB minimum the service offers for creating
    # storage. Both end up in one JBOD pool below.
    virtualisation.emptyDiskImages = [
      2048
      2048
    ];
  };

  testScript = ''
    import json

    machine.start()
    for unit in ["casaos-gateway.service", "casaos-user-service.service", "recasanix-storage.service"]:
        machine.wait_for_unit(unit)
    machine.wait_for_open_port(80)
    machine.succeed("test \"$(systemctl show recasanix-storage.service -p NRestarts --value)\" = 0")

    # --- an administrator and a token, the way a user gets one ---------------------------------------
    machine.succeed("printf 'admin\\nrecasanix-admin-pass-1\\n' | recasanix-user-admin bootstrap")
    machine.wait_for_unit("casaos-user-service.service")
    login = json.loads(machine.succeed(
        "curl -s -X POST -H 'Content-Type: application/json' "
        "-d '{\"username\":\"admin\",\"password\":\"recasanix-admin-pass-1\"}' http://localhost/v1/users/login"
    ))["data"]["token"]
    access, refresh = login["access_token"], login["refresh_token"]

    def call(method, path, bearer=None, body=None):
        auth = f"-H 'Authorization: Bearer {bearer}' " if bearer else ""
        data = f"-H 'Content-Type: application/json' -d '{body}' " if body else ""
        out = machine.succeed(f"curl -s -w '\\n%{{http_code}}' -X {method} {auth}{data}http://localhost{path}")
        text, code = out.rsplit("\n", 1)
        return int(code), (json.loads(text) if text.strip().startswith(("{", "[")) else text)

    # the browser runs on the test driver and reaches the machine through a forwarded port
    machine.forward_port(host_port=8090, guest_port=80)

    def browser(phase):
        import os
        import subprocess

        env = dict(
            os.environ,
            HOME="/tmp",
            PLAYWRIGHT_BROWSERS_PATH="${pkgs.playwright-driver.browsers}",
            PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS="true",
            FONTCONFIG_FILE="${fonts}",
        )
        result = subprocess.run(
            ["${python}/bin/python", "${panelScript}", "http://localhost:8090", "admin", "recasanix-admin-pass-1", phase],
            env=env, capture_output=True, text=True, timeout=300,
        )
        print(result.stdout)
        print(result.stderr[-3000:])
        assert result.returncode == 0, f"storage manager UI check ({phase}) failed (output above)"

    # --- nobody gets in without a valid access token ---------------------------------------------------
    for path in ["/v1/disks", "/v1/storage", "/v1/disks/usb", "/v2/local_storage/merge"]:
        code, _ = call("GET", path)
        assert code == 401, f"{path} without a token -> {code}"
        code, _ = call("GET", path, bearer="not-a-token")
        assert code == 401, f"{path} with garbage -> {code}"
        # a refresh token is a valid JWT from the same user service, but not an access token
        code, _ = call("GET", path, bearer=refresh)
        assert code == 401, f"{path} with a refresh token -> {code}"

    # --- disks: the two blank ones are available, the system disk is labelled ---------------------------
    code, r = call("GET", "/v1/disks", access)
    assert code == 200 and r["success"] == 200, r
    disks = {d["name"]: d for d in r["data"]["disks"]}
    avail = {d["name"] for d in r["data"]["avail"]}
    assert {"vda", "vdb", "vdc"} <= set(disks), sorted(disks)
    assert avail == {"vdb", "vdc"}, avail
    assert disks["vda"]["model"] == "System", disks["vda"]
    for name in ["vdb", "vdc"]:
        d = disks[name]
        assert d["need_format"] is True and d["children"] == [] and d["size"] == 2048 * 1024 * 1024, d
        # virtual disks do not answer SMART: that must not look like a failing disk
        assert d["health"] == "true" and d["temperature"] == 0, d
    # the UI iterates these: lists, never null
    assert isinstance(r["data"]["avail"], list) and isinstance(disks["vdb"]["children"], list)

    # --- storage: with the system disk on request; nothing else is mounted yet -------------------------
    code, r = call("GET", "/v1/storage?system=show", access)
    assert code == 200, r
    system = [s for s in r["data"] if s["disk_name"] == "System"]
    assert len(system) == 1, r
    root = [v for v in system[0]["children"] if v["mount_point"] == "/"]
    assert len(root) == 1 and root[0]["label"] and root[0]["size"].isdigit(), system
    code, r = call("GET", "/v1/storage", access)
    assert code == 200 and r["data"] == [], r  # no pool yet, and the system disk is not asked for

    # --- v1 USB and the v2 merge answer emptily, not with errors -----------------------------------------
    code, r = call("GET", "/v1/disks/usb", access)
    assert code == 200 and r["data"] == [], r
    code, r = call("GET", "/v2/local_storage/merge", access)
    assert code == 200 and r["data"] == [] and "success" not in r, r

    # --- changes to an *existing* storage are refused, and say why; nothing on the machine changes -------
    # (POST /v1/storage is not in this list: creating a new one is supported, exercised below.)
    before = machine.succeed("lsblk -b -o NAME,FSTYPE,LABEL,MOUNTPOINTS")
    for method, path, body in [
        ("PUT", "/v1/storage", '{"path":"/dev/vdb","mount_point":"/DATA/x"}'),
        ("DELETE", "/v1/storage", '{"path":"/dev/vdb"}'),
        ("DELETE", "/v1/disks", '{"path":"/dev/vdb"}'),
        ("DELETE", "/v1/disks/usb", '{"mount_point":"/tmp"}'),
        ("POST", "/v2/local_storage/mount", '{"mount_point":"/DATA/x"}'),
        ("POST", "/v2/local_storage/merge", "{}"),
    ]:
        code, r = call(method, path, access, body)
        assert code == 501 and "not available yet" in r["message"], f"{method} {path} -> {code} {r}"
    assert machine.succeed("lsblk -b -o NAME,FSTYPE,LABEL,MOUNTPOINTS") == before

    # --- creating is rejected up front for everything that is not "a currently blank, available disk,
    # to be formatted" — and rejecting never touches a disk -------------------------------------------
    root_before = machine.succeed("findmnt -n -o SOURCE /").strip()
    for label, path, fmt in [
        ("made up", "/dev/does-not-exist", True),
        ("the system disk", "/dev/vda", True),
        ("mount without formatting", "/dev/vdb", False),
    ]:
        code, r = call("POST", "/v1/storage", access, f'{{"path":"{path}","format":{"true" if fmt else "false"}}}')
        assert code not in (200, 201), f"{label} ({path}) was accepted: {code} {r}"
    for bearer in (None, "not-a-token", refresh):
        code, r = call("POST", "/v1/storage", bearer, '{"path":"/dev/vdb","format":true}')
        assert code == 401, f"create without a valid access token -> {code}"
    assert not machine.succeed("blkid /dev/vdb /dev/vdc || true").strip(), "a rejected request formatted a disk"
    assert machine.succeed("findmnt -n -o SOURCE /").strip() == root_before, "the system disk's root mount changed"

    # --- the real UI creates the first storage: the gear, the form, "Format and create", a success
    # toast — not the read-only refusal this used to be, and the panel must not get stuck (UI patch
    # 0004) -------------------------------------------------------------------------------------------
    browser("blank")
    machine.wait_until_succeeds("blkid -L recasanix-data", timeout=30)
    machine.wait_until_succeeds("mountpoint -q /var/lib/recasanix/data", timeout=30)

    code, r = call("GET", "/v1/disks", access)
    assert {d["name"] for d in r["data"]["avail"]} == {"vdc"}, \
        f"vdb was just created on, vdc is still blank: {r['data']['avail']}"

    # --- a second disk, added through the API: extends the same pool instead of making a new one -------
    code, r = call("POST", "/v1/storage", access, '{"path":"/dev/vdc","format":true}')
    assert code == 200 and r["success"] == 200, r
    machine.wait_until_succeeds("systemctl is-active DATA.mount docker.service", timeout=30)

    code, r = call("GET", "/v1/storage", access)
    assert code == 200, r
    volumes = [v for disk in r["data"] for v in disk["children"]]
    assert len(volumes) == 1, f"one pool on two disks must be listed once: {r['data']}"
    v = volumes[0]
    assert v["label"] == "recasanix-data" and v["type"] == "btrfs" and v["mount_point"] == "/DATA", v
    assert v["size"].isdigit() and v["avail"].isdigit() and v["used"].isdigit() and int(v["size"]) > 0, v
    assert v["uuid"], v
    # declared by the operating system's configuration (the pool mount is a NixOS fileSystems entry)
    assert v["persisted_in"] == "fstab", v

    code, r = call("GET", "/v1/disks", access)
    assert {d["name"] for d in r["data"]["disks"]} >= {"vdb", "vdc"}, r
    assert r["data"]["avail"] == [], f"both disks are used now: {r['data']['avail']}"

    # JBOD, as asked for: btrfs's default "single" profile across both disks, not a mirror
    df = machine.succeed("btrfs filesystem df /var/lib/recasanix/data")
    assert "single" in df.lower() and "raid1" not in df.lower(), df
    assert machine.succeed("btrfs filesystem show /var/lib/recasanix/data | grep -c devid").strip() == "2"

    # --- re-creating on a disk that is already part of the pool is refused, and the pool is untouched ---
    uuid_before = machine.succeed("btrfs filesystem show /var/lib/recasanix/data | grep -o 'uuid: [^ ]*'")
    code, r = call("POST", "/v1/storage", access, '{"path":"/dev/vdb","format":true}')
    assert code not in (200, 201), f"an in-use disk was accepted for creation again: {code} {r}"
    assert machine.succeed("btrfs filesystem show /var/lib/recasanix/data | grep -o 'uuid: [^ ]*'") == uuid_before

    # --- the real UI, again: now the (two-disk, JBOD) pool is there -------------------------------------
    browser("pool")

    # --- the service is quiet, confined, and casaos/docker actually came up on the new pool -------------
    errors = machine.succeed("journalctl -u recasanix-storage.service -p err --no-pager --quiet").strip()
    assert not errors, f"recasanix-storage logged errors:\n{errors}"
    machine.succeed("systemctl show recasanix-storage.service -p NoNewPrivileges --value | grep -qx yes")
    machine.succeed("systemctl show recasanix-storage.service -p ProtectSystem --value | grep -qx strict")
    machine.succeed("systemctl is-active DATA.mount docker.service casaos.service casaos-app-management.service")
    machine.succeed("test \"$(systemctl show recasanix-storage.service -p NRestarts --value)\" = 0")

    # --- the gateway restarts and forgets its (deliberately unpersisted) service routes: the service
    # notices and registers again, without being restarted itself ---------------------------------------
    machine.succeed("systemctl restart casaos-gateway.service")
    machine.wait_for_open_port(80)
    machine.wait_until_succeeds(
        f"curl -s -o /dev/null -w '%{{http_code}}' -H 'Authorization: Bearer {access}' http://localhost/v1/disks | grep -x 200",
        timeout=120,
    )
    machine.succeed("test \"$(systemctl show recasanix-storage.service -p NRestarts --value)\" = 0")
  '';
}

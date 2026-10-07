# T13 — network shares (AGENTS.md §2, "SMB"). Nix owns smb.conf and includes the fragment the root
# service publishes in include-only mode; shares are restricted to separate SMB accounts created
# through the API. Asserted with a real smbd and smbclient: the account gets in and owns what it writes,
# other accounts, guests and wrong passwords do not; system accounts cannot be enrolled; the fragment
# is regenerated from the share database; accounts and their passwords survive a reboot.
# Upstream: ReCasaOS#153, #154 (merged).
{ pkgs, modules }:
pkgs.testers.runNixOSTest {
  name = "recasanix-smb-shares";

  nodes.machine = {
    imports = [
      modules.appliance
      modules.storage
      modules.state
      modules.recasaos
    ];
    services.recasaos.enable = true;
    recasanix.state.enable = true;
    recasanix.appliance.admin.initialHashedPassword = "!";
    virtualisation.memorySize = 2048;
  };

  testScript = ''
    import json

    def boot():
        machine.start()
        for unit in ["casaos.service", "casaos-user-service.service", "samba-smbd.service"]:
            machine.wait_for_unit(unit)
        machine.wait_for_open_port(80)
        machine.wait_for_open_port(445)

    boot()

    with subtest("Nix owns smb.conf; the root service runs in include-only mode"):
        machine.succeed("test -L /etc/samba/smb.conf")
        machine.succeed("grep -qx 'SambaMainConfig *= *external' /etc/casaos/casaos.conf")
        signing = machine.succeed("testparm -s --parameter-name='server signing' 2>/dev/null").strip().lower()
        assert signing in ("mandatory", "required"), signing
        machine.succeed("systemctl restart smbd")  # the name the root service restarts it by

    machine.succeed("printf 'admin\\nrecasanix-admin-pass-1\\n' | recasanix-user-admin bootstrap")
    machine.wait_for_unit("casaos-user-service.service")
    auth = ""

    def log_in():
        global auth
        login = json.loads(machine.succeed(
            "curl -s -X POST -H 'Content-Type: application/json' "
            "-d '{\"username\":\"admin\",\"password\":\"recasanix-admin-pass-1\"}' http://localhost/v1/users/login"
        ))
        auth = "-H 'Authorization: Bearer " + login["data"]["token"]["access_token"] + "'"

    log_in()

    def api(method, path, body=None):
        data = "-H 'Content-Type: application/json' -d " + json.dumps(json.dumps(body)) if body is not None else ""
        out = machine.succeed(f"curl -s -X {method} {auth} {data} http://localhost{path}")
        return json.loads(out)

    def ok(method, path, body=None):
        out = api(method, path, body)
        assert out.get("success") == 200, f"{method} {path} -> {out}"
        return out

    def refused(method, path, body=None):
        out = api(method, path, body)
        assert out.get("success") != 200, f"{method} {path} was accepted: {out}"
        return out

    def smb(user, command, share="Media"):
        creds = f"-U {user}" if user else "-N"
        return machine.execute(f"cd /tmp && smbclient //localhost/{share} {creds} -m SMB3 -c {json.dumps(command)} 2>&1")

    with subtest("share accounts, never system accounts"):
        ok("POST", "/v1/samba/users", {"username": "alice", "password": "alice-pass-1"})
        ok("POST", "/v1/samba/users", {"username": "bob", "password": "bob-pass-1"})
        users = ok("GET", "/v1/samba/users")["data"]
        assert sorted(users) == ["alice", "bob"], users
        machine.succeed("getent passwd alice | grep -q ':CasaOS share account:[^:]*:[^:]*/nologin$'")
        refused("POST", "/v1/samba/users", {"username": "root", "password": "x"})
        refused("PUT", "/v1/samba/users/root/password", {"password": "x"})
        machine.fail("pdbedit -L | grep -q '^root:'")

    with subtest("a share restricted to alice"):
        machine.succeed("mkdir -p /DATA/Media")
        ok("POST", "/v1/samba/shares", [{"path": "/DATA/Media", "username": "alice"}])
        machine.succeed("grep -q 'valid users = alice' /etc/samba/smb.casa.conf")
        machine.succeed("test \"$(stat -c '%U %a' /DATA/Media)\" = 'alice 770'")
        machine.succeed("echo hello > /tmp/hello.txt")
        status, out = smb("alice%alice-pass-1", "put hello.txt; ls")
        assert status == 0 and "hello.txt" in out, out
        machine.succeed("test \"$(stat -c %U /DATA/Media/hello.txt)\" = alice")
        for user in ["bob%bob-pass-1", "alice%wrong-password", None]:
            status, out = smb(user, "ls")
            assert status != 0, f"{user} got in: {out}"

    with subtest("an account in use cannot be deleted"):
        refused("DELETE", "/v1/samba/users/alice")
        machine.succeed("getent passwd alice")

    with subtest("the fragment is derived state: regenerated from the share database"):
        machine.succeed("rm /etc/samba/smb.casa.conf && systemctl restart casaos.service")
        machine.wait_for_unit("casaos.service")
        machine.wait_until_succeeds("grep -q 'valid users = alice' /etc/samba/smb.casa.conf", timeout=60)
        status, out = smb("alice%alice-pass-1", "ls")
        assert status == 0, out

    with subtest("accounts and passwords survive a reboot"):
        machine.succeed("systemctl start recasanix-accounts-sync.service")
        machine.shutdown()
        boot()
        machine.succeed("getent passwd alice")
        machine.wait_until_succeeds("grep -q 'valid users = alice' /etc/samba/smb.casa.conf", timeout=60)
        status, out = smb("alice%alice-pass-1", "ls")
        assert status == 0 and "hello.txt" in out, out
        log_in()  # sessions do not survive a restart

    with subtest("lifting the restriction and removing the share return the directory to root"):
        share_id = ok("GET", "/v1/samba/shares")["data"][0]["id"]
        ok("PUT", f"/v1/samba/shares/{share_id}", {"username": "bob"})
        machine.succeed("test \"$(stat -c '%U %a' /DATA/Media)\" = 'bob 770'")
        ok("DELETE", f"/v1/samba/shares/{share_id}")
        machine.succeed("test \"$(stat -c '%U %a' /DATA/Media)\" = 'root 755'")
        ok("DELETE", "/v1/samba/users/alice")
        machine.fail("getent passwd alice")
        machine.fail("pdbedit -L | grep -q '^alice:'")
  '';
}

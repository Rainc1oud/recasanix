# T4 — state persistence: the cold/hot boundary of task 3.2. Hot state (ReCasaOS accounts and databases,
# runtime-created unix users, SSH host keys, configuration changed at runtime) must survive both a reboot
# and the *replacement of the root disk* — which is what an image update does — while vendor-owned files
# come back to their store content and cannot be tampered with persistently.
{ pkgs, modules }:
pkgs.testers.runNixOSTest {
  name = "recasanix-state-persistence";

  nodes.machine = {
    imports = [
      modules.appliance
      modules.storage
      modules.state
      modules.recasaos
    ];
    services.recasaos.enable = true;
    recasanix.appliance.admin.initialHashedPassword = "!";
    recasanix.state = {
      enable = true;
      device = "/dev/vdb"; # the first extra disk
      autoFormat = true;
    };
    virtualisation.emptyDiskImages = [ 256 ];
    virtualisation.memorySize = 2048;
  };

  testScript = ''
    import json
    import os

    units = [
        "casaos-gateway.service",
        "casaos-message-bus.service",
        "casaos.service",
        "casaos-user-service.service",
        "casaos-app-management.service",
    ]

    def up():
        for unit in units:
            machine.wait_for_unit(unit)
        machine.wait_for_open_port(80)

    def login():
        r = json.loads(machine.succeed(
            "curl -s -X POST -H 'Content-Type: application/json' "
            "-d '{\"username\":\"admin\",\"password\":\"recasanix-admin-pass-1\"}' http://localhost/v1/users/login"
        ))
        return r["data"]["token"]["access_token"]

    machine.start()
    up()
    machine.succeed("findmnt -M /var/lib/recasanix/state -t ext4")

    with subtest("hot state is created and lives on the state filesystem"):
        machine.succeed("printf 'admin\\nrecasanix-admin-pass-1\\n' | recasanix-user-admin bootstrap")
        machine.wait_for_unit("casaos-user-service.service")
        token = login()
        # the boot-time mirror must already have run, so the copy asserted below can only come from the
        # change trigger (not from a boot-time sync that happened to run after useradd)
        machine.wait_until_succeeds("test -e /var/lib/recasanix/state/accounts/passwd")
        machine.sleep(3)
        # a user created at runtime the way CasaOS/the operator would (ordinary useradd, hot state)
        machine.succeed("useradd -m alice")
        uid = machine.succeed("id -u alice").strip()
        machine.wait_until_succeeds("grep -q '^alice:' /var/lib/recasanix/state/accounts/passwd", timeout=30)
        # config the services write at runtime
        machine.succeed("sed -i 's/^port=.*/port=80/; $a # touched at runtime' /etc/casaos/gateway.ini")
        host_key = machine.succeed("ssh-keygen -lf /var/lib/recasanix/state/ssh/ssh_host_ed25519_key.pub").strip()
        # the services' hardened storage code refuses symlinks, so these are bind mounts of state directories
        for path, src in [("/etc/casaos", "casaos-etc"), ("/var/lib/casaos", "casaos")]:
            machine.succeed(f"findmnt -n -o SOURCE --target {path} | grep -q '\\[/{src}\\]'")
        machine.succeed("test -e /var/lib/recasanix/state/casaos-etc/recasaos-user-bootstrap.seal")
        # vendor-owned: tamper with it, and with the executed start.d directory
        machine.succeed("rm -rf /var/lib/casaos/www && mkdir /var/lib/casaos/www && echo tampered > /var/lib/casaos/www/index.html")
        machine.succeed("echo 'touch /tmp/pwned' > /etc/casaos/start.d/evil.sh")

    def replace_root_and_reboot():
        machine.shutdown()
        # what an image update does: the root filesystem is replaced, the state filesystem is not
        roots = [f for f in os.listdir(machine.state_dir) if f.endswith(".qcow2") and not f.startswith("empty")]
        assert roots, os.listdir(machine.state_dir)
        for f in roots:
            os.remove(os.path.join(machine.state_dir, f))
        machine.start()

    with subtest("hot state survives a reboot and the replacement of the root"):
        replace_root_and_reboot()
        up()
        machine.succeed("findmnt -M /var/lib/recasanix/state -t ext4")
        # ReCasaOS: the database (admin account) and the bootstrap seal came back — login works, no re-bootstrap
        machine.succeed("curl -s http://localhost/v1/users/status | grep -q '\"initialized\":true'")
        token = login()
        # the runtime-created unix user, with the same uid
        assert machine.succeed("id -u alice").strip() == uid
        # SSH host key unchanged
        assert machine.succeed("ssh-keygen -lf /var/lib/recasanix/state/ssh/ssh_host_ed25519_key.pub").strip() == host_key
        machine.succeed("ssh-keygen -lf /var/lib/recasanix/state/ssh/ssh_host_ed25519_key.pub | grep -q ED25519")
        # runtime-written config kept
        machine.succeed("grep -q 'touched at runtime' /etc/casaos/gateway.ini")

    with subtest("vendor-owned files return to their store content"):
        machine.succeed("curl -fsS http://localhost/ | grep -qi '<html'")
        machine.fail("grep -q tampered /var/lib/casaos/www/index.html")
        machine.succeed("test -L /var/lib/casaos/www")
        machine.fail("test -e /etc/casaos/start.d/evil.sh")
        machine.succeed("test \"$(ls /etc/casaos/start.d)\" = register-ui-events.sh")
        machine.fail("test -e /tmp/pwned")

    with subtest("a second replacement of the root still finds everything"):
        replace_root_and_reboot()
        up()
        token = login()
        assert machine.succeed("id -u alice").strip() == uid
  '';
}

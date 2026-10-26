# T16 — the virtual-machines module (CasaOS-VirtManagement, pinned by modules.env, built into the image):
# enabled from the Modules page (image provider), it starts against socket-activated libvirtd, finds QEMU
# and UEFI firmware, makes its VM network with its own iptables chains, answers on the gateway; removed,
# it stops and is not started at boot. No guest is booted (nested virtualisation is not assumed).
{ pkgs, modules }:
pkgs.testers.runNixOSTest {
  name = "recasanix-virt-module";

  nodes.machine = {
    imports = [
      modules.appliance
      modules.storage
      modules.recasaos
    ];
    services.recasaos.enable = true;
    recasanix.appliance.admin.initialHashedPassword = "!";
    virtualisation.memorySize = 3072;
    environment.systemPackages = [ pkgs.jq ];
  };

  testScript = ''
    import json

    for unit in ["casaos-gateway.service", "casaos.service", "casaos-user-service.service"]:
        machine.wait_for_unit(unit)
    machine.wait_for_open_port(80)
    machine.succeed("printf 'admin\\nrecasanix-admin-pass-1\\n' | recasanix-user-admin bootstrap")
    machine.wait_for_unit("casaos-user-service.service")

    # one login (the user service rate-limits logins; the polls below would trip it); valid for hours,
    # again after a reboot only if the key changed (it does not: hot state)
    _token = []

    def token():
        if _token:
            return _token[0]
        _token.append(json.loads(machine.succeed(
            "curl -s -X POST -H 'Content-Type: application/json' "
            "-d '{\"username\":\"admin\",\"password\":\"recasanix-admin-pass-1\"}' http://localhost/v1/users/login"
        ))["data"]["token"]["access_token"])
        return _token[0]

    def api(method, path, body=None):
        data = f"-H 'Content-Type: application/json' -d '{json.dumps(body)}'" if body is not None else ""
        return json.loads(machine.succeed(f"curl -s -X {method} -H 'Authorization: {token()}' {data} http://localhost{path}"))

    def wait_job(kind):
        machine.wait_until_succeeds(
            f"curl -s -H 'Authorization: {token()}' http://localhost/v1/sys/modules/virt/status "
            f"| jq -e '.data.job.kind == \"{kind}\" and .data.job.state != \"running\"'",
            timeout=180,
        )
        return api("GET", "/v1/sys/modules/virt/status")["data"]

    with subtest("in the image, off: listed, nothing running"):
        mods = api("GET", "/v1/sys/modules")["data"]
        virt = [m for m in mods["modules"] if m["name"] == "virt"]
        assert mods["catalogue"]["ok"] is True and virt and virt[0]["installed"] is None, mods
        assert virt[0]["tag"] == "v0.2.3", virt
        machine.fail("systemctl is-active casaos-virt-management.service")
        machine.fail("systemctl is-active libvirtd.service")

    with subtest("enable from the Modules page: the module answers on the gateway"):
        plan = api("POST", "/v1/sys/modules/virt/plan")["data"]
        assert not plan["refused"], plan
        api("POST", "/v1/sys/modules/virt/install", {"plan_id": plan["plan_id"]})
        status = wait_job("install")
        assert status["job"]["state"] == "succeeded", status
        assert status["status"]["unit"]["active"] and status["status"]["route"]["answers"], status

    with subtest("libvirt (socket-activated), QEMU and UEFI firmware found; the VM network made"):
        machine.wait_until_succeeds(
            f"curl -s -H 'Authorization: {token()}' http://localhost/v2/virt_management/host | jq -e '.data.libvirt == \"available\"'",
            timeout=120,
        )
        host = api("GET", "/v2/virt_management/host")["data"]
        assert host["uefi"] is True and host["storage_path"] == "/DATA/VM", host
        machine.succeed("systemctl is-active libvirtd.service")
        machine.wait_until_succeeds("virsh -c qemu:///system net-list --all | grep -q casaos", timeout=60)
        machine.wait_until_succeeds("iptables -t filter -S CASAOS-VM | grep -q casaos0", timeout=60)
        machine.succeed("test -e /etc/casaos/virt-management.conf")

    with subtest("remove: stopped, flag gone, not started at boot"):
        api("POST", "/v1/sys/modules/virt/remove", {})
        status = wait_job("remove")
        assert status["job"]["state"] == "succeeded", status
        machine.fail("systemctl is-active casaos-virt-management.service")
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("casaos.service")
        machine.fail("systemctl is-active casaos-virt-management.service")
  '';
}

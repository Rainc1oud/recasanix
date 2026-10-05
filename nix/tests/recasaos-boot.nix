# T2 — the primary integration test: the real appliance modules plus services.recasaos on one
# machine. All five units come up (first time, without restarts), the gateway serves the UI, the
# root service is reachable through the gateway, the fork's hardening is in force, and the shell
# helpers actually run in the service's own environment (a missing PATH entry is invisible at build
# time and only shows up as a runtime `command not found`).
{ pkgs, modules }:
pkgs.testers.runNixOSTest {
  # (runNixOSTest already uses this pkgs: overlay + the UI's unfree allowance)
  name = "recasanix-recasaos-boot";

  nodes.machine = {
    imports = [
      modules.appliance
      modules.storage
      modules.recasaos
    ];
    services.recasaos.enable = true;
    recasanix.appliance.admin.initialHashedPassword = "!";
    virtualisation.memorySize = 2048;
  };

  testScript = ''
    import json

    units = [
        "casaos-gateway.service",
        "casaos-message-bus.service",
        "casaos.service",
        "casaos-user-service.service",
        "casaos-app-management.service",
    ]
    machine.start()
    for unit in units:
        machine.wait_for_unit(unit)

    # no unit needed a restart to get up (a first-start failure papered over by Restart=always)
    for unit in units:
        machine.succeed(f"test \"$(systemctl show {unit} -p NRestarts --value)\" = 0")

    machine.wait_for_open_port(80)
    machine.succeed("curl -fsS http://localhost/ | grep -qi '<html'")

    # the root service registered its routes with the gateway: an unauthenticated API call is
    # refused by the service (401), not answered with the gateway's 404/502
    machine.wait_until_succeeds(
        "curl -s -o /dev/null -w '%{http_code}' http://localhost/v1/sys/utilization | grep -x 401",
        timeout=60,
    )

    # the fork's hardening must still be in force
    machine.succeed("systemctl show casaos-user-service.service -p UMask | grep -q 0077")

    # Local-only administrator bootstrap: the fork never takes a setup secret over HTTP.
    machine.succeed("curl -s http://localhost/v1/users/status | grep -q '\"initialized\":false'")
    machine.succeed("curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost/v1/users/register | grep -x 410")
    machine.succeed("printf 'admin\\nrecasanix-admin-pass-1\\n' | recasanix-user-admin bootstrap")
    machine.wait_for_unit("casaos-user-service.service")
    machine.succeed("curl -s http://localhost/v1/users/status | grep -q '\"initialized\":true'")
    # the credential sources are gone, and the bootstrap cannot be replayed
    machine.succeed("test -z \"$(ls -A /run/recasaos-user-bootstrap)\"")
    machine.fail("printf 'evil\\nrecasanix-evil-pass-1\\n' | recasanix-user-admin bootstrap")
    machine.wait_for_unit("casaos-user-service.service")

    # log in and use the API
    login = json.loads(machine.succeed(
        "curl -s -X POST -H 'Content-Type: application/json' "
        "-d '{\"username\":\"admin\",\"password\":\"recasanix-admin-pass-1\"}' http://localhost/v1/users/login"
    ))
    token = login["data"]["token"]["access_token"]
    # The root service only accepts `Authorization: Bearer <token>` (user-service also takes the bare
    # token). The pinned UI used to send the bare token, so every root-service call from the browser
    # was a 401 and login looked dead; the UI is patched to send Bearer (casaos-ui patch 0003).
    def api(method, path):
        return machine.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}}' -X {method} -H 'Authorization: Bearer {token}' http://localhost{path}"
        )

    code = api("GET", "/v1/sys/utilization")
    assert code == "200", f"utilization -> {code}"

    # The UI calls this right after login and treats any failure as a failed login: it must answer
    # locally (no network update check) with the running version.
    version = json.loads(machine.succeed(f"curl -s -H 'Authorization: Bearer {token}' http://localhost/v1/sys/version"))
    assert version["success"] == 200 and version["data"]["need_update"] is False, version
    assert version["data"]["current_version"], version

    # the removed self-update / self-kill routes are gone (guardrail)
    for method, path in [("POST", "/v1/sys/update"), ("POST", "/v1/sys/stop")]:
        code = api(method, path)
        assert code in ("404", "405"), f"{method} {path} -> {code}"

    # The helpers must run in the service's own environment, not just exist on disk: take PATH from
    # the unit and source helper.sh exactly the way the Go code does.
    machine.succeed(
        "path=$(systemctl show casaos.service -p Environment --value | tr ' ' '\\n' | sed -n 's/^PATH=//p') && "
        "test -n \"$path\" && "
        "env -i PATH=\"$path\" bash -c '"
        "source /usr/share/casaos/shell/helper.sh; GetSysInfo; GetTimeZone; GetNetCard 1'"
        " 2>&1 | tee /tmp/helper.out"
    )
    machine.fail("grep -q 'command not found' /tmp/helper.out")
    machine.succeed("grep -q 'Bit:' /tmp/helper.out")  # GetSysInfo printed (needs getconf, free, uname)
    machine.fail("journalctl -u casaos.service | grep -q 'command not found'")
  '';
}

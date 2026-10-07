# T12 — the trust boundary between the CasaOS services. Loopback is not an identity: any local
# process, and any container on the host network, reaches the services' listeners. The message bus
# and app management skip the user token only for an in-stack caller — one that presents the
# gateway's per-start service credential (/run/casaos/gateway.token, root-only), or that really
# arrived on the bus's root-only unix socket. Upstream PRs, carried as patches until merged:
# recasaos-message-bus 0004–0006, recasaos-app-management 0002–0004, recasaos-user-service 0002–0003,
# recasaos 0004–0005, casaos-ui 0005. Also the power actions (recasaos 0006): the UI's shutdown
# button reaches systemd.
{ pkgs, modules }:
pkgs.testers.runNixOSTest {
  name = "recasanix-service-auth";

  nodes.machine = {
    imports = [
      modules.appliance
      modules.storage
      modules.recasaos
    ];
    services.recasaos.enable = true;
    recasanix.appliance.admin.initialHashedPassword = "!";
    virtualisation.memorySize = 2048;
    environment.systemPackages = [ pkgs.jq ];
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
    machine.wait_for_open_port(80)
    machine.wait_until_succeeds("test -s /run/casaos/app-management.url && test -s /run/casaos/message-bus.url")

    bus = machine.succeed("cat /run/casaos/message-bus.url").strip()
    apps = machine.succeed("cat /run/casaos/app-management.url").strip()
    # the credential travels through a file descriptor, never on a command line
    cred = "-H @<(printf 'Authorization: Bearer %s\\n' \"$(< /run/casaos/gateway.token)\")"

    def code(cmd):
        """HTTP status of a curl run under bash (for the process substitution in `cred`)."""
        return machine.succeed("bash -c " + json.dumps(f"curl -s -o /dev/null -w '%{{http_code}}' {cmd}")).strip()

    def expect(cmd, *codes):
        got = code(cmd)
        assert got in codes, f"curl {cmd} -> {got}, want one of {codes}"

    with subtest("the credential is root-only"):
        machine.succeed("test \"$(stat -c '%U %a' /run/casaos/gateway.token)\" = 'root 600'")
        machine.succeed("test \"$(stat -c '%U %a' /tmp/message-bus.sock)\" = 'root 600'")

    with subtest("in-stack callers present the credential: everything registered, no 401 at the bus"):
        # root service, user service, app management and the UI's start.d script all register event
        # types at startup; with the bus enforcing the credential, a caller without it fails here
        machine.wait_until_succeeds(
            "bash -c " + json.dumps(f"curl -sf {cred} {bus}/v2/message_bus/event_type | jq -e 'map(.sourceID) | unique | length >= 3'"),
            timeout=120,
        )
        sources = json.loads(machine.succeed(
            "bash -c " + json.dumps(f"curl -sf {cred} {bus}/v2/message_bus/event_type | jq -c 'map(.sourceID) | unique'")
        ))
        print("event sources:", sources)
        assert "app-management" in sources, sources
        assert "casaos" in sources, sources
        machine.fail("journalctl -u casaos-message-bus.service | grep -q '\"status\":401'")
        machine.fail("journalctl -u casaos.service -u casaos-user-service.service -u casaos-app-management.service | grep -qi 'failed to register'")

    with subtest("message bus: loopback alone is not an identity"):
        expect(f"{bus}/v2/message_bus/event_type", "401")
        expect(f"-H 'Authorization: Bearer not-the-credential' {bus}/v2/message_bus/event_type", "401")
        expect(f"{cred} {bus}/v2/message_bus/event_type", "200")

    with subtest("message bus: Host: unix proves nothing, also not through the gateway"):
        expect(f"-H 'Host: unix' {bus}/v2/message_bus/event_type", "401")
        expect("-H 'Host: unix' http://localhost/v2/message_bus/event_type", "401")
        # the gateway reports the client's address as the forwarded source: from the LAN address the
        # bus sees a non-loopback client (pinned upstream answered 200 here, with every event type)
        lan = machine.succeed("ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1").strip()
        expect(f"http://{lan}/v2/message_bus/event_type", "401")
        expect(f"-H 'Host: unix' http://{lan}/v2/message_bus/event_type", "401")
        # and a local process does not get in through the gateway either
        expect("http://localhost/v2/message_bus/event_type", "401")

    with subtest("message bus: the unix socket is root-only"):
        expect("--unix-socket /tmp/message-bus.sock http://unix/v2/message_bus/event_type", "200")
        machine.fail("runuser -u nobody -- curl -sf --unix-socket /tmp/message-bus.sock http://unix/v2/message_bus/event_type")

    with subtest("app management: loopback alone is not an identity"):
        expect(f"{apps}/v2/app_management/compose", "401")
        # past authentication (this VM has no data pool, so Docker is not running and the handler
        # itself answers 500)
        expect(f"{cred} {apps}/v2/app_management/compose", "200", "500")
        expect(f"{apps}/v1/container", "401")

    # Power: the UI's shutdown button ends in `systemctl poweroff`, and the API says so only when
    # systemd took the job (it used to run SysV `init 0`, which NixOS lacks, and answer 200 anyway).
    with subtest("power off from the API"):
        machine.succeed("printf 'admin\\nrecasanix-admin-pass-1\\n' | recasanix-user-admin bootstrap")
        machine.wait_for_unit("casaos-user-service.service")
        login = json.loads(machine.succeed(
            "curl -s -X POST -H 'Content-Type: application/json' "
            "-d '{\"username\":\"admin\",\"password\":\"recasanix-admin-pass-1\"}' http://localhost/v1/users/login"
        ))
        token = login["data"]["token"]["access_token"]
        # Backgrounded with every fd redirected: the machine powers off under the test driver's own
        # shell, so the request cannot be a `succeed` (no exit status would ever come back). The
        # 200-vs-500 answer is covered by the PR's unit tests; here: systemd got the job from casaos.
        machine.execute(
            f"curl -s -o /dev/null -X PUT "
            f"-H 'Authorization: Bearer {token}' http://localhost/v1/sys/state/off "
            "</dev/null >/dev/console 2>&1 &"
        )
        machine.wait_for_console_text(r"poweroff requested from client .*\(unit casaos\.service\)")
        machine.wait_for_shutdown()
  '';
}

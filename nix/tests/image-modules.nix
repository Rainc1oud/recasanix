# T15 — modules of the image (`[server] ImageManaged`, CasaOS image provider): the Modules page's
# routes enable and disable a module the image ships. On NixOS: systemctl found through the unit's
# PATH, the unit started at boot only where enabled (ConditionPathExists= on the flag), the route
# through the gateway. A demo module: a unit that registers /v2/demo at the gateway and answers it.
{ pkgs, modules }:
let
  demo = {
    name = "demo";
    component = "CasaOS-Demo";
    tier = "core";
    tag = "v0.1.0";
    commit = "0123456789abcdef0123456789abcdef01234567";
    manifest = {
      schema = 1;
      name = "demo";
      title = "Demo";
      description = "A module of the image.";
      component = "CasaOS-Demo";
      unit = "casaos-demo.service";
      gateway_route = "/v2/demo";
      packages = { };
      min_recasaos = "0.5.0";
      os = [ "debian:12" ];
    };
  };
  serve = pkgs.writeShellScript "casaos-demo" ''
    set -eu
    mgmt=$(cat /run/casaos/management.url)
    curl -fsS -X POST -H "Authorization: Internal $(cat /run/casaos/internal.secret)" \
      -H 'Content-Type: application/json' -d '{"path":"/v2/demo","target":"http://127.0.0.1:8899"}' \
      "$mgmt/v1/gateway/routes"
    mkdir -p /run/casaos-demo/v2/demo && echo demo > /run/casaos-demo/v2/demo/index.html
    exec ${pkgs.python3}/bin/python3 -m http.server --bind 127.0.0.1 --directory /run/casaos-demo 8899
  '';
in
pkgs.testers.runNixOSTest {
  name = "recasanix-image-modules";

  nodes.machine = {
    imports = [
      modules.appliance
      modules.storage
      modules.recasaos
    ];
    services.recasaos = {
      enable = true;
      imageModules = [ demo ];
      modules.virt.enable = false; # the demo alone (virt: T16)
    };
    recasanix.appliance.admin.initialHashedPassword = "!";
    virtualisation.memorySize = 2048;

    # the module's unit, as an image ships it: started at boot only where enabled
    systemd.services.casaos-demo = {
      description = "Demo module of the image";
      after = [ "casaos-gateway.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "/var/lib/casaos/modules/demo.enabled";
      path = [ pkgs.curl ];
      serviceConfig.ExecStart = serve;
    };
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
        return json.loads(machine.succeed(f"curl -s -X {method} -H 'Authorization: {token()}' {data} http://localhost/v1/sys/modules{path}"))

    def wait_job(kind):
        machine.wait_until_succeeds(
            f"curl -s -H 'Authorization: {token()}' http://localhost/v1/sys/modules/demo/status "
            f"| ${pkgs.jq}/bin/jq -e '.data.job.kind == \"{kind}\" and .data.job.state != \"running\"'",
            timeout=120,
        )
        return api("GET", "/demo/status")["data"]

    with subtest("listed, not installed; the unit not started at boot"):
        mods = api("GET", "")["data"]
        assert mods["catalogue"]["ok"] is True, mods
        assert [(m["name"], m["installed"]) for m in mods["modules"]] == [("demo", None)], mods
        machine.fail("systemctl is-active casaos-demo.service")

    with subtest("install: flag, unit started, route answers"):
        plan = api("POST", "/demo/plan")["data"]
        assert plan["refused"] is None or plan["refused"] == "", plan
        assert {c["code"]: c["ok"] for c in plan["checks"]}["catalogue"] is True, plan
        api("POST", "/demo/install", {"plan_id": plan["plan_id"]})
        status = wait_job("install")
        assert status["job"]["state"] == "succeeded", status
        assert status["status"]["unit"]["active"] and status["status"]["route"]["answers"], status
        machine.succeed("test -f /var/lib/casaos/modules/demo.enabled")
        machine.succeed("curl -fsS http://localhost/v2/demo/ | grep -q demo")

    with subtest("enabled: started at boot"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("casaos-demo.service")

    with subtest("update: the image is the release"):
        machine.wait_for_unit("casaos.service")
        machine.wait_for_open_port(80)
        machine.wait_until_succeeds("curl -sf http://localhost/v1/users/status >/dev/null")
        plan = api("POST", "/demo/plan", {"mode": "update"})["data"]
        assert plan["refused"] == "up_to_date", plan

    with subtest("remove: unit stopped, flag gone, not started at boot"):
        api("POST", "/demo/remove", {})
        status = wait_job("remove")
        assert status["job"]["state"] == "succeeded" and not status["status"]["installed"], status
        machine.fail("systemctl is-active casaos-demo.service")
        machine.fail("test -e /var/lib/casaos/modules/demo.enabled")
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("casaos.service")
        machine.fail("systemctl is-active casaos-demo.service")
  '';
}

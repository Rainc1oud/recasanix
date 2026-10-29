# T18 — the storage layer (docs/storage-layer.md) end to end through the gateway: /v2/storage plans
# and applies on real disks, on two machines.
# - btrfs: create a mirror (2 disks) → add a disk → 3 copies → replace a disk → back to 2 copies →
#   remove a disk → wipe a foreign disk → a member unplugged → replace it → whole again
# - md: create parity (RAID 5, 3 disks) → grow to 4 → a member failed → replace it → a member
#   missing at boot → inactive → mount degraded → replace → whole
# Every destructive plan needs its typed confirmation; a wrong one changes nothing.
{ pkgs, modules }:
let
  node = disks: {
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
    virtualisation.emptyDiskImages = disks;
  };
in
pkgs.testers.runNixOSTest {
  name = "recasanix-storage-layer";

  nodes.btrfs = node [
    2048
    2048
    2048
    2048
  ];
  nodes.md = node [
    1024
    1024
    1024
    1024
    1024
  ];

  testScript = ''
    import json
    import time

    def login(m):
        for unit in ["casaos-gateway.service", "casaos-user-service.service", "recasanix-storage.service"]:
            m.wait_for_unit(unit)
        m.wait_for_open_port(80)
        m.succeed("printf 'admin\\nrecasanix-admin-pass-1\\n' | recasanix-user-admin bootstrap")
        m.wait_for_unit("casaos-user-service.service")
        return json.loads(m.succeed(
            "curl -s -X POST -H 'Content-Type: application/json' "
            "-d '{\"username\":\"admin\",\"password\":\"recasanix-admin-pass-1\"}' http://localhost/v1/users/login"
        ))["data"]["token"]["access_token"]

    class Box:
        def __init__(self, m):
            self.m, self.token = m, login(m)

        def call(self, method, path, body=None):
            data = f"-H 'Content-Type: application/json' -d '{json.dumps(body)}' " if body is not None else ""
            out = self.m.succeed(f"curl -s -w '\\n%{{http_code}}' -X {method} -H 'Authorization: {self.token}' {data}http://localhost{path}")
            text, code = out.rsplit("\n", 1)
            return int(code), json.loads(text)

        def view(self):
            code, r = self.call("GET", "/v2/storage")
            assert code == 200, r
            return r["data"]

        def pool(self):
            return self.view()["pool"]

        def roles(self):
            return {d["name"]: d["role"] for d in self.view()["drives"]}

        def plan(self, intent):
            code, r = self.call("POST", "/v2/storage/plans", intent)
            assert code == 200, f"{intent} -> {code} {r}"
            return r["data"]

        def refused(self, intent, why):
            code, r = self.call("POST", "/v2/storage/plans", intent)
            assert code == 409 and why in r["message"], f"{intent} -> {code} {r}"

        def apply(self, intent):
            p = self.plan(intent)
            if p["confirm"]:
                code, r = self.call("POST", f"/v2/storage/plans/{p['id']}/apply", {"confirm": "wrong"})
                assert code == 400, f"a wrong confirmation -> {code} {r}"
            code, r = self.call("POST", f"/v2/storage/plans/{p['id']}/apply", {"confirm": p["confirm"]})
            assert code == 202, f"apply {intent} -> {code} {r}"
            job = r["data"]["id"]
            for _ in range(600):
                jobs = {j["id"]: j for j in self.view()["jobs"]}
                if jobs[job]["state"] != "running":
                    assert jobs[job]["state"] == "done", jobs[job]
                    return p
                time.sleep(1)
            raise AssertionError(f"job of {intent} never ended")

        def wait(self, what, pred, timeout=600):
            for _ in range(timeout):
                p = self.pool()
                if p and pred(p):
                    return p
                time.sleep(1)
            raise AssertionError(f"pool never {what}: {self.pool()}")

    def unplug(m, disk):
        m.succeed(f"echo 1 > $(readlink -f /sys/block/{disk}/device/..)/remove")

    def stop_pool(m):
        m.succeed("systemctl stop casaos.service casaos-app-management.service docker.service docker.socket DATA.mount var-lib-recasanix-data.mount")

    def members(p):
        return sorted(x["name"] for x in p["members"] if x["state"] == "active")

    start_all()

    # ======================= btrfs ===================================================================
    b = Box(btrfs)
    v = b.view()
    assert v["pool"] is None and v["busy"] is False, v
    assert b.roles() == {"vda": "system", "vdb": "free", "vdc": "free", "vdd": "free", "vde": "free"}, b.roles()
    code, r = b.call("GET", "/v2/storage/layouts?disks=vdb,vdc")
    opts = {(o["layout"]["kind"], o["layout"].get("copies", 0) or o["layout"].get("parity", 0)): o for o in r["data"]}
    assert opts[("mirror", 2)]["possible"] and not opts[("parity", 1)]["possible"], r

    # a wrong confirmation changes nothing
    before = btrfs.succeed("lsblk -b -o NAME,FSTYPE,LABEL")
    p = b.plan({"verb": "create-pool", "layout": {"kind": "mirror", "copies": 2}, "disks": ["vdb", "vdc"]})
    code, _ = b.call("POST", f"/v2/storage/plans/{p['id']}/apply", {"confirm": "vdb"})
    assert code == 400 and btrfs.succeed("lsblk -b -o NAME,FSTYPE,LABEL") == before

    b.apply({"verb": "create-pool", "layout": {"kind": "mirror", "copies": 2}, "disks": ["vdb", "vdc"]})
    p = b.wait("mounted", lambda p: p["mounted"])
    assert p["backend"] == "btrfs" and p["profile"] == "raid1" and p["tolerates"] == 1 and members(p) == ["vdb", "vdc"], p
    btrfs.succeed("systemctl is-active DATA.mount docker.service casaos.service")
    btrfs.succeed("dd if=/dev/urandom of=/DATA/blob bs=1M count=64 conv=fsync && sha256sum /DATA/blob > /tmp/blob.sum")

    b.apply({"verb": "add-disk", "disks": ["vdd"]})
    assert members(b.pool()) == ["vdb", "vdc", "vdd"]

    b.apply({"verb": "change-layout", "layout": {"kind": "mirror", "copies": 3}})
    p = b.wait("3 copies", lambda p: p["profile"] == "raid1c3" and p["state"] == "ok")
    assert p["tolerates"] == 2, p
    b.refused({"verb": "remove-disk", "member": "vdd"}, "needs at least 3 disks")

    b.apply({"verb": "replace-disk", "member": "vdd", "disks": ["vde"]})
    p = b.wait("replaced", lambda p: p["state"] == "ok" and members(p) == ["vdb", "vdc", "vde"])
    assert b.roles()["vdd"] == "free", b.roles()  # btrfs clears the replaced disk

    # back to 2 copies: less protection, typed (the pool's name), then a disk can go
    b.apply({"verb": "change-layout", "layout": {"kind": "mirror", "copies": 2}})
    b.wait("2 copies", lambda p: p["profile"] == "raid1" and p["state"] == "ok")
    b.apply({"verb": "remove-disk", "member": "vde"})
    p = b.wait("2 disks", lambda p: members(p) == ["vdb", "vdc"])
    btrfs.succeed("sha256sum -c /tmp/blob.sum")

    # a foreign disk is offered for wiping, not for use
    btrfs.succeed("mkfs.ext4 -q /dev/vde && udevadm settle")
    assert b.roles()["vde"] == "foreign", b.roles()
    b.refused({"verb": "add-disk", "disks": ["vde"]}, "not blank")
    b.apply({"verb": "wipe-disk", "disks": ["vde"]})
    assert b.roles()["vde"] == "free", b.roles()

    # a member unplugged while mounted: degraded; replaced from the mirror's other copy
    unplug(btrfs, "vdc")
    btrfs.succeed("dd if=/dev/urandom of=/DATA/after bs=1M count=8 conv=fsync")
    p = b.wait("degraded", lambda p: p["state"] == "degraded")
    assert p["tolerates"] == 0 and "replace-disk" in p["verbs"], p
    b.apply({"verb": "replace-disk", "member": "vdc", "disks": ["vdd"]})
    p = b.wait("whole again", lambda p: p["state"] == "ok" and members(p) == ["vdb", "vdd"])
    assert p["tolerates"] == 1, p
    btrfs.succeed("sha256sum -c /tmp/blob.sum")

    # unmounted with a disk gone (as after a reboot): btrfs will not mount it by itself
    stop_pool(btrfs)
    unplug(btrfs, "vdd")
    p = b.wait("inactive", lambda p: p["state"] == "inactive" and not p["mounted"])
    assert p["verbs"] == ["mount-degraded"], p
    b.apply({"verb": "mount-degraded"})
    p = b.wait("mounted degraded", lambda p: p["mounted"] and p["state"] == "degraded")
    btrfs.succeed("systemctl is-active DATA.mount docker.service && sha256sum -c /tmp/blob.sum")
    gone = [x["name"] for x in p["members"] if x["state"] == "faulty"]
    b.apply({"verb": "replace-disk", "member": gone[0], "disks": ["vde"]})
    b.wait("whole again", lambda p: p["state"] == "ok" and members(p) == ["vdb", "vde"])
    btrfs.succeed("sha256sum -c /tmp/blob.sum")

    # ======================= md (parity) =============================================================
    d = Box(md)
    d.refused({"verb": "create-pool", "layout": {"kind": "parity", "parity": 1}, "disks": ["vdb", "vdc"]}, "needs at least 3 disks")
    d.apply({"verb": "create-pool", "layout": {"kind": "parity", "parity": 1}, "disks": ["vdb", "vdc", "vdd"]})
    # small virtual disks: no throttling of resync / reshape (the md module is loaded now)
    md.succeed("echo 2000000 > /proc/sys/dev/raid/speed_limit_max && echo 1000000 > /proc/sys/dev/raid/speed_limit_min")
    p = d.wait("built", lambda p: p["mounted"] and p["state"] == "ok")
    assert p["backend"] == "md" and p["profile"] == "raid5" and p["tolerates"] == 1 and p["disks"] == 3, p
    md.succeed("systemctl is-active DATA.mount docker.service")
    md.succeed("dd if=/dev/urandom of=/DATA/blob bs=1M count=64 conv=fsync && sha256sum /DATA/blob > /tmp/blob.sum")
    # the v1 create cannot put a raw disk next to the array
    code, r = d.call("POST", "/v1/storage", {"path": "/dev/vde", "format": True})
    assert code == 409 and "parity pool" in r["message"], r

    size = p["size"]
    d.apply({"verb": "add-disk", "disks": ["vde"]})  # the job waits for the reshape, then grows the fs
    p = d.wait("grown", lambda p: p["disks"] == 4 and p["state"] == "ok" and p["size"] > size)

    md.succeed("mdadm /dev/md/recasanix-data --fail /dev/vdc")
    p = d.wait("degraded", lambda p: p["state"] == "degraded")
    assert [x for x in p["members"] if x["name"] == "vdc"][0]["state"] == "faulty", p
    d.apply({"verb": "replace-disk", "member": "vdc", "disks": ["vdf"]})
    d.wait("rebuilt", lambda p: p["state"] == "ok" and "vdf" in members(p))
    md.succeed("sha256sum -c /tmp/blob.sum")

    # a member missing at boot: md assembles incrementally (udev) and leaves the array inactive; the
    # pool is mounted degraded on request, then the missing disk replaced
    stop_pool(md)
    md.succeed("mdadm --stop /dev/md/recasanix-data && wipefs -a /dev/vdb /dev/vdc && udevadm settle")
    md.succeed("for disk in vdd vde vdf; do mdadm --incremental /dev/$disk; done")
    p = d.wait("inactive", lambda p: p["state"] == "inactive" and not p["mounted"])
    assert p["verbs"] == ["mount-degraded"], p
    d.apply({"verb": "mount-degraded"})
    p = d.wait("mounted degraded", lambda p: p["mounted"] and p["state"] == "degraded")
    md.succeed("sha256sum -c /tmp/blob.sum")
    d.apply({"verb": "replace-disk", "disks": ["vdb"]})  # no member named: in place of the missing one
    p = d.wait("whole again", lambda p: p["state"] == "ok" and p["missing"] == 0)
    assert p["tolerates"] == 1, p
    md.succeed("sha256sum -c /tmp/blob.sum")
  '';
}

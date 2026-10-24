{
  lib,
  mkCasaosGo,
  oapi-codegen-v1,
  components,
  src,
}:
# A module (CasaOS-Install release/modules.env), built into the image like a component and enabled per
# box from the Modules page. Runtime dependencies, not build ones: libvirtd (its socket), qemu-img and
# iptables/iptables-restore (the VM network's chains); the NixOS module supplies them through the
# unit's `path`.
mkCasaosGo {
  pname = "casaos-virt-management";
  version = lib.removePrefix "v" components.recasaos-virt-management.tag;
  inherit src;
  vendorHash = "sha256-IMbts9oYodKSYTrB5MAJDihlmQbu+Y400NUds1EM02E=";
  subPackages = [ "." ];
  renameBinaries.CasaOS-VirtManagement = "casaos-virt-management";
  repo = components.recasaos-virt-management.repo;
  description = "ReCasaOS virtual machines module: libvirt/QEMU VMs, their network, disks, ISOs and consoles";
  mainProgram = "casaos-virt-management";

  # the module's catalogue entry for the image (source image added by the NixOS module): the pins of
  # modules.env and the module.json at the pinned commit
  passthru.catalogueEntry = {
    inherit (components.recasaos-virt-management.module)
      name
      component
      tier
      manifest
      ;
    inherit (components.recasaos-virt-management) tag;
    commit = components.recasaos-virt-management.rev;
  };

  # codegen/ is gitignored and made by `go generate` from the network; here the pinned generator
  # (postPatch also runs in the vendoring derivation)
  nativeBuildInputs = [ oapi-codegen-v1 ];
  postPatch = ''
    mkdir -p codegen
    oapi-codegen -generate types,server,spec -package codegen \
      api/virt_management/openapi.yaml > codegen/virt_management_api.go
  '';
}

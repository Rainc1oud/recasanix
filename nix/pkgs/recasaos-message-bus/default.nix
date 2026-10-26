{
  lib,
  mkCasaosGo,
  components,
  src,
}:
mkCasaosGo {
  pname = "casaos-message-bus";
  version = lib.removePrefix "v" components.recasaos-message-bus.tag;
  inherit src;
  vendorHash = "sha256-kPDytFE4X4UseWPFP46WaLuR3PlxmhM97uvhISn5emU=";
  subPackages = [ "." ];
  renameBinaries.CasaOS-MessageBus = "casaos-message-bus";
  repo = components.recasaos-message-bus.repo;
  description = "ReCasaOS message bus: event publish/subscribe between the CasaOS services";
  mainProgram = "casaos-message-bus";
}

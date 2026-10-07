{
  mkCasaosGo,
  components,
  src,
}:
mkCasaosGo {
  pname = "casaos-message-bus";
  # upstream: common/constants.go
  version = "0.4.4";
  inherit src;
  vendorHash = "sha256-VZ8cZq9ceiVI8JfB+KVHX+yBVyWHgdsQ+zRNS69XY/k=";
  patches = [
    ./patches/0001-accept-bearer-authorization.patch
    ./patches/0002-fix-service-startup-races-in-the-event-and-action-di.patch
    ./patches/0003-test-ysk-wait-for-the-cards-instead-of-sleeping.patch
    ./patches/0004-security-route-take-unix-socket-identity-from-the-co.patch
    ./patches/0005-feat-gatewayclient-service-credential-helpers-for-in.patch
    ./patches/0006-security-route-loopback-needs-the-gateway-service-cr.patch
    ./patches/0007-feat-route-one-use-subscription-tickets-for-browser-.patch
    ./patches/0008-fix-route-subscriptions-need-a-ticket.patch
  ];
  subPackages = [ "." ];
  renameBinaries.CasaOS-MessageBus = "casaos-message-bus";
  repo = components.recasaos-message-bus.repo;
  description = "ReCasaOS message bus: event publish/subscribe between the CasaOS services";
  mainProgram = "casaos-message-bus";
}

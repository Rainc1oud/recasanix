# recasanix-user-admin — local, root-only account lifecycle for ReCasaOS.
#
# The first administrator is never created over HTTP (`[app] FirstAdmin = local`: no register key,
# POST /v1/users/register → 403), so bootstrap is a local operation: credentials are handed to a
# oneshot unit through systemd's LoadCredential from root-only files, never through arguments,
# environment, journal or shell history. A password reset uses upstream's `-ru`: it sets a random
# password, clears two-factor authentication and prints the new password here (not in the journal).
set -euo pipefail

usage() {
  cat >&2 <<USAGE
Usage: recasanix-user-admin bootstrap
       recasanix-user-admin reset-password <username>

  bootstrap        create the first administrator (only works once); username and password are
                   read from the terminal (or two lines on stdin), never accepted as arguments
  reset-password   give an account a new random password (printed here) and turn off its
                   two-factor authentication
USAGE
  exit 2
}

[ $# -ge 1 ] || usage
if [ "$(id -u)" -ne 0 ]; then
  exec /run/wrappers/bin/sudo "$0" "$@"
fi

daemon=casaos-user-service.service

case "$1" in
  bootstrap)
    [ $# -eq 1 ] || usage
    ;;
  reset-password)
    [ $# -eq 2 ] && [ -n "$2" ] || usage
    # the account store only; the running service would keep a stale view → stop it meanwhile
    systemctl stop "$daemon"
    status=0
    casaos-user-service -c /etc/casaos/user-service.conf -ru -user "$2" | grep -v '^\(git commit\|build date\):' || status=$?
    systemctl start "$daemon"
    exit "$status"
    ;;
  *) usage ;;
esac

unit=recasaos-user-bootstrap
dir=/run/$unit

if [ -t 0 ]; then
  read -r -p "Username: " username
  read -r -s -p "Password: " password
  echo
  read -r -s -p "Repeat password: " again
  echo
  [ "$password" = "$again" ] || {
    echo "passwords differ" >&2
    exit 1
  }
else
  read -r username
  read -r password
fi
[ -n "$username" ] && [ -n "$password" ] || {
  echo "username and password must not be empty" >&2
  exit 1
}

cleanup() {
  rm -f -- "$dir/username" "$dir/password"
}
trap cleanup EXIT

# root-owned 0700 directory, root-owned 0600 files (the unit reads them as credentials)
install -d -m 0700 -o root -g root "$dir"
umask 077
printf '%s' "$username" >"$dir/username"
printf '%s' "$password" >"$dir/password"
unset password again

systemctl stop "$daemon"
status=0
systemctl start "$unit.service" || status=$?

# the unit removes the sources itself; make sure, whatever happened
for f in "$dir/username" "$dir/password"; do
  if [ -e "$f" ]; then
    echo "warning: credential source $f survived the unit; removing it" >&2
    rm -f -- "$f"
  fi
done

systemctl start "$daemon"

if [ "$status" -ne 0 ]; then
  echo "$unit failed (see: journalctl -u $unit)" >&2
  exit "$status"
fi
echo "done"

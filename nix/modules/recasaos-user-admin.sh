# recasanix-user-admin — local, root-only account lifecycle for ReCasaOS.
#
# The fork never accepts an administrator setup secret over HTTP (POST /v1/users/register answers
# 410 Gone), so the first administrator, and any password reset, is a local operation: credentials are
# handed to a oneshot unit through systemd's LoadCredential from root-only files, never through
# arguments, environment, journal or shell history. This script drives that documented lifecycle:
# stop the daemon, run the oneshot, verify the credential files are gone, start the daemon again.
set -euo pipefail

usage() {
  cat >&2 <<USAGE
Usage: recasanix-user-admin <command>

  bootstrap              create the first administrator (only works once)
  reset-admin-password   replace an existing administrator's password
  reset-user-password    replace an existing non-administrator's password

The username and password are read from the terminal (or, when stdin is not a terminal,
from two lines on stdin). They are never accepted as arguments.
USAGE
  exit 2
}

[ $# -eq 1 ] || usage
case "$1" in
  bootstrap)
    unit=recasaos-user-bootstrap
    password_file=password
    ;;
  reset-admin-password)
    unit=recasaos-user-password-reset
    password_file=new-password
    ;;
  reset-user-password)
    unit=recasaos-user-account-password-reset
    password_file=new-password
    ;;
  *) usage ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  exec /run/wrappers/bin/sudo "$0" "$@"
fi

dir=/run/$unit
daemon=casaos-user-service.service

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
  rm -f -- "$dir/username" "$dir/$password_file"
}
trap cleanup EXIT

# root-owned 0700 directory, root-owned 0600 files (the unit reads them as credentials)
install -d -m 0700 -o root -g root "$dir"
umask 077
printf '%s' "$username" >"$dir/username"
printf '%s' "$password" >"$dir/$password_file"
unset password again

systemctl stop "$daemon"
status=0
systemctl start "$unit.service" || status=$?

# the unit removes the sources itself; make sure, whatever happened
for f in "$dir/username" "$dir/$password_file"; do
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

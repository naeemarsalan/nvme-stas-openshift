#!/bin/bash
# Verified working 2026-09-21 against nvme-stas-2.2.1-2.el9 in a privileged,
# hostNetwork container (no hostPID, no hostIPC) on a 6.19 kernel with nvme_tcp loaded.
set -e

UDEV_OVERRIDE=/run/udev/rules.d/70-nvmf-autoconnect.rules

cleanup() {
    # stafd 2.2.1 writes UDEV_OVERRIDE at startup to suppress nvme-cli's TCP
    # autoconnect, and is supposed to remove it in Staf._release_resources().
    # VERIFIED: it does NOT get removed when stafd dies inside a container.
    # Left behind, the node has neither nvme-cli autoconnect nor a running stacd.
    rm -f "$UDEV_OVERRIDE"
    kill "$STAC_PID" "$STAF_PID" "$DBUS_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup TERM INT EXIT

# UBI9 ships a zero-length /etc/machine-id; dbus-daemon refuses to start without one.
dbus-uuidgen --ensure

# systemd normally creates these via RuntimeDirectory=; nothing does in a container.
# Without them stafd/stacd log "Unable to save last known config: [Errno 2] ...
# /run/stafd/last-known-config.pickle" on every config cycle and forget their
# controller list across restarts.
mkdir -p /run/dbus /run/stafd /run/stacd

# Clear any override left behind by a previously crashed instance.
rm -f "$UDEV_OVERRIDE"

# Fail loudly if the node's NVMe identity was not mounted in.
[ -s /etc/nvme/hostnqn ] || { echo "FATAL: /etc/nvme/hostnqn missing - mount the node's /etc/nvme" >&2; exit 1; }

# PRIVATE system bus. Listens on /run/dbus/system_bus_socket inside the pod, which is
# also GLib's compiled-in default (GLIB_RUNSTATEDIR "/dbus/system_bus_socket"), so
# stafd/stacd need no DBUS_SYSTEM_BUS_ADDRESS. Set that variable only if you move it.
# The name-ownership policy files that the host does not have
# (/usr/share/dbus-1/system.d/org.nvmexpress.{staf,stac}.conf) ship in THIS image and
# are picked up by <includedir>system.d</includedir> in /usr/share/dbus-1/system.conf.
# dbus-daemon --system tries to setuid to the 'dbus' user and drop capabilities. Under
# OpenShift's privileged SCC that fails with "Failed to drop capabilities: Operation not
# permitted" and the daemon exits, leaving a socket file with nothing behind it (the
# clients then see "Connection refused"). Verified on OCP 4.20.32 / RHCOS 9.6; it does
# NOT reproduce under plain podman, which is why this is easy to miss.
# Strip <user> so it stays root, and make <includedir> absolute, because our copy lives
# outside /usr/share/dbus-1 and the shipped path is relative - without that the
# org.nvmexpress.{staf,stac}.conf policy files are never loaded and RequestName is
# refused by policy.
sed -e '/<user>/d' \
    -e 's|<includedir>system.d</includedir>|<includedir>/usr/share/dbus-1/system.d</includedir>|' \
    /usr/share/dbus-1/system.conf > /run/dbus/bus.conf
dbus-daemon --config-file=/run/dbus/bus.conf --nofork &
DBUS_PID=$!
for i in $(seq 1 20); do [ -S /run/dbus/system_bus_socket ] && break; sleep 0.5; done
kill -0 "$DBUS_PID" 2>/dev/null || { echo "FATAL: dbus-daemon died on startup" >&2; exit 1; }

# No --syslog: 2.2.1 sends journal output to /run/systemd/journal/socket (absent here)
# and stdout logging is what `oc logs` wants. Caveat: staslib/log.py hard-couples
# "not syslog" to logging.DEBUG, so this is verbose. To get INFO-level into the node
# journal instead, pass --syslog AND mount hostPath /run/systemd/journal.
/usr/sbin/stacd & STAC_PID=$!
sleep 2
/usr/sbin/stafd & STAF_PID=$!

wait -n

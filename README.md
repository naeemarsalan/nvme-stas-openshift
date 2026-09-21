# nvme-stas on OpenShift, as a DaemonSet

Running [nvme-stas](https://github.com/linux-nvme/nvme-stas) (`stafd` + `stacd`) on RHCOS
worker nodes without modifying the node image.

## The situation

nvme-stas is the NVMe-oF discovery client: `stafd` talks to Discovery Controllers and
handles Asynchronous Event Notifications, `stacd` establishes the I/O controller
connections. On RHEL you install it and move on.

RHCOS is different. It does not ship nvme-stas, and there is no package manager at
runtime, so "install it" has no equivalent. That leaves two options.

**Image layering.** Build a custom RHCOS image with the RPM baked in, via image mode for
OpenShift. This is a supported mechanism and it works. The costs are a rebuild for every
RHCOS update, a larger node image, and the RPM's dependency closure landing on every node.
On EL9 that closure is 26 packages, including cairo, libX11, freetype, harfbuzz,
fontconfig and the avahi daemon, because `python3-gobject` pulls in the X11 stack. Fonts
and X libraries on a headless server OS, to get a storage daemon.

**A DaemonSet.** Put nvme-stas in a container, give it the host's NVMe identity and device
nodes, and let it act on the host kernel from there. The node image stays stock. The
dependency closure becomes image bytes rather than node bytes. Updates are a tag change.

This repo is the second one.

## Does it actually work?

Yes. Verified on OpenShift 4.20.32 / RHCOS 9.6 across three nodes:

- both D-Bus names owned (`org.nvmexpress.staf`, `org.nvmexpress.stac`)
- `stacd` connected to `stafd`, config loop iterating
- per-node host NQN read from the node's `/etc/nvme`
- `last-known-config.pickle` persisted to the node's `/run`, surviving pod restarts
- on DaemonSet removal, the udev override correctly cleaned off the node

Not verified here: a live connection to a real NVMe-oF target. The test cluster had no
array. The mechanism is sound (NVMe fabric connections are kernel objects, not namespaced,
so a connection made from a privileged container with `/dev` mounted lands on the host)
but if you deploy this, prove it against your own target first.

Note also that upstream ships `CONTAINERS.md` saying containers are not a supported
deployment target. Worth reading before you commit to this. The counterpoint is that
nvme-stas 2.2.1, the version in EL9, shipped its own `Dockerfile` and `docker-compose.yml`
upstream; those were removed in 3.0.

## Five things that will bite you

Each of these cost a debug cycle. They are the reason this repo exists.

**1. Do not mount the host's D-Bus socket.**
`stafd` and `stacd` own bus names. EL9's `system.conf` denies name ownership by default,
and the exceptions are punched by `/usr/share/dbus-1/system.d/org.nvmexpress.{staf,stac}.conf`,
which ship in the RPM and therefore do not exist on a stock RHCOS node. Mount the host bus
and you get:

```
DBusError: Request to own name refused by policy
```

Run a private system bus inside the pod instead. The policy files are in the image, so the
bus already has the right holes, and the host is never touched.

**2. `dbus-daemon --system` will not start under the privileged SCC.**
It tries to setuid to the `dbus` user and drop capabilities:

```
Failed to start message bus: Failed to drop capabilities: Operation not permitted
```

It then exits, leaving a socket file with nothing listening, so clients report
"Connection refused" and you go looking in the wrong place. Strip the `<user>` directive
from the bus config. This does **not** reproduce under plain `podman run --privileged`,
which is what makes it easy to miss.

**3. The policy includedir is relative.**
`<includedir>system.d</includedir>` in `system.conf` resolves relative to the config file.
Write your modified config anywhere else and the nvme-stas policy files silently stop
loading, and you are back to error 1. Make it absolute.

**4. UBI ships a zero-length `/etc/machine-id`.**
`dbus-daemon` will not start without one. `dbus-uuidgen --ensure` fixes it.

**5. `stafd` leaves a udev override behind when it dies.**
At startup it writes `/run/udev/rules.d/70-nvmf-autoconnect.rules` to suppress nvme-cli's
own autoconnect, and it does not remove it when it dies inside a container. Left there,
the node has neither nvme-cli autoconnect nor a running `stacd`, and nothing reports an
error. The entrypoint traps `TERM INT EXIT` to remove it, and the DaemonSet adds a
`preStop` hook. Grace-period expiry and eviction SIGKILL are not covered by either, so
this is worth a periodic check in production.

## Requirements you cannot skip

**`hostNetwork: true`**, for two independent reasons:

- `staslib/udev.py` uses `pyudev.Monitor.from_netlink(source='udev')`. systemd-udevd
  rebroadcasts to that group only in the host network namespace. In a pod netns `stafd`
  is permanently deaf to `NVME_AEN=0x70f002` DISCOVERY_LOG_CHANGE, with no error.
- `nvme_tcp_alloc_queue()` calls `sock_create_kern(current->nsproxy->net_ns, ...)`.
  Kernel-driven reconnects run on a kworker with `init_nsproxy`, so a connection first
  made inside a pod netns would reconnect from a different source address. Invisible
  until your first path failure.

**hostPath `/etc/nvme`.** Without it every pod presents the NQN baked into the image at
build time, identical on every node. The Containerfile deletes `/etc/nvme/hostnqn` so a
missing mount fails loudly instead of silently collapsing your whole cluster onto one
host record. An init container checks it too.

**hostPath, not emptyDir, for `/run/stafd` and `/run/stacd`.** `stacd` adopts an existing
kernel connection only if it appears in `last-known-config.pickle`. An emptyDir is wiped
on every pod restart, so after a rollout `stacd` comes up owning nothing while the
previous instance's connections are still live in the kernel, unmanaged and never reaped.
The node's `/run` tmpfs has exactly the right lifetime: survives a pod restart, cleared by
a reboot, which is when the connections die anyway.

**`zeroconf=disabled`** unless you actually need mDNS. It removes the Avahi dependency,
and with it the reason the RPM's closure is so large.

## A version skew to be aware of

RHCOS 4.20.22 ships `nvme-cli 2.11-7.el9_6` and `libnvme 1.11.1`, built from RHEL 9.6
content. Current RHEL 9 AppStream is at `nvme-cli 2.16-1.el9`, so a container built from
it carries a newer nvme-cli and libnvme than the node does. `stacd` acts on the host
kernel through `/dev/nvme-fabrics` via libnvme, so the userspace doing the connecting is
the container's, not the node's. That worked in testing, but it is a real boundary and
worth checking against your own kernel and array.

## Why restarts are safe

`Stac._keep_connections_on_exit()` returns `True` in 2.2.1. On SIGTERM `stacd` drops its
userspace handle and leaves every I/O controller in the host kernel. A rollout, a drain or
a crash loop causes no I/O interruption, and a fresh instance adopts the existing
controllers rather than reconnecting. The kernel also refuses a duplicate connect with
`-EALREADY`, so a confused restart cannot double-connect.

## Usage

Build and push:

```bash
podman build -t ghcr.io/OWNER/nvme-stas:2.2.1-el9 .
podman push ghcr.io/OWNER/nvme-stas:2.2.1-el9
```

**Build on an entitled RHEL host.** nvme-stas is in `rhel-9-for-x86_64-appstream-rpms`
and is *not* in the `ubi-9-*` repos, so a plain unentitled UBI build cannot reach it.
On an entitled host podman bind-mounts `/etc/pki/entitlement` and the RHEL repos resolve,
giving you `vendor=Red Hat, Inc.` signed packages. This is the same requirement OpenShift
documents for layering RHEL packages onto RHCOS.

The `Containerfile` carries a commented CentOS Stream fallback for labs without
entitlement. It pulls the same NVRAs, but they come out `vendor=CentOS` with `gpgcheck=0`,
so most land unsigned. Do not ship that build.

Pin an image digest rather than a tag. A mutable tag with the default `IfNotPresent`
policy means a rebuilt image silently never rolls out.

Deploy:

```bash
oc new-project nvme-stas
oc adm policy add-scc-to-user privileged -z nvme-stas -n nvme-stas
oc apply -f 99-worker-nvme-tcp-modules-load.yaml   # loads nvme_tcp at boot
oc apply -f daemonset.yaml
```

Point it at your Discovery Controller by editing the `[Controllers]` section of the
`stafd.conf` key in the ConfigMap.

Verify:

```bash
oc logs -n nvme-stas ds/nvme-stas
oc exec -n nvme-stas ds/nvme-stas -- \
  dbus-send --system --dest=org.freedesktop.DBus --print-reply \
  /org/freedesktop/DBus org.freedesktop.DBus.ListNames | grep nvmexpress
```

Then, from the node, `nvme list-subsys` should show the controllers `stacd` created.

## One thing to check before you start

RHCOS nodes can all carry an identical `/etc/nvme/hostnqn`, since it is generated at image
compose time rather than per node. Arrays key masking on host NQN, so check this first:

```bash
for n in $(oc get nodes -o name); do
  oc debug $n -- chroot /host cat /etc/nvme/hostnqn 2>/dev/null
done
```

If they match, fix that with a MachineConfig before deploying anything, whichever delivery
mechanism you choose.

## Files

| File | What it is |
|---|---|
| `Containerfile` | Builds the image. UBI9 base, nvme-stas from AppStream. |
| `entrypoint.sh` | Private D-Bus, identity check, cleanup trap. |
| `daemonset.yaml` | ServiceAccount, ConfigMap, DaemonSet. Every non-obvious field is commented. |
| `99-worker-nvme-tcp-modules-load.yaml` | MachineConfig to load `nvme_tcp` at boot. |

## License

Apache-2.0, matching upstream nvme-stas.

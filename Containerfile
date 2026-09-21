# Verified to build and run: nvme-stas 2.2.1-2.el9 + a PRIVATE system D-Bus inside the pod.
# The host system bus is never touched, so the host needs no D-Bus policy files.
FROM registry.access.redhat.com/ubi9/ubi:latest

# Replace c9s mirrors with your entitled RHEL 9 AppStream and BaseOS repos for production.
RUN printf '%s\n' '[c9s-appstream]' 'name=c9s-appstream' \
      'baseurl=https://mirror.stream.centos.org/9-stream/AppStream/$basearch/os/' \
      'gpgcheck=0' 'enabled=1' > /etc/yum.repos.d/c9s-appstream.repo && \
    printf '%s\n' '[c9s-baseos]' 'name=c9s-baseos' \
      'baseurl=https://mirror.stream.centos.org/9-stream/BaseOS/$basearch/os/' \
      'gpgcheck=0' 'enabled=1' > /etc/yum.repos.d/c9s-baseos.repo && \
    dnf -y install nvme-stas nvme-cli dbus-daemon kmod && dnf clean all
# kmod: for the load-nvme-tcp init container (modprobe). el9 kmod-28 is built +XZ +ZSTD,
# so it reads the node's .ko.xz module tree. Drop it only if you switch that init
# container to the nsenter form, which uses the node's own modprobe.

# nvme-stas ships /usr/share/dbus-1/system.d/org.nvmexpress.{staf,stac}.conf in THIS image,
# and dbus-daemon's /usr/share/dbus-1/system.conf has <includedir>system.d</includedir>,
# so the private bus already carries the name-ownership holes. Nothing to add.

# Delete the image-baked host identity so a missing /etc/nvme hostPath fails loudly
# instead of silently presenting a cluster-wide-identical NQN to the array.
RUN rm -f /etc/nvme/hostnqn /etc/nvme/hostid

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

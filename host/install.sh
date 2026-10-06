#!/bin/bash
# Install a release on the MutinyNet parent. Run as root over SSM by deploy.sh, which has just put
# the release under s3://$bucket/artifacts/:
#
#   eif/enclave.eif, eif/pcr.json   the enclave image
#   bin/gvproxy, bin/merlin-platform
#   host/                           this script, the platform's and Caddy's units, enclave-pins.json
#   host/units/                     enclave-runtime's parent units, from the commit flake.lock pins
#
# The instance is stock Amazon Linux 2023: the first run sets the parent up, and every run brings it
# to what the release says. The enclave restarts onto the new image and resumes its store; the
# platform restarts onto its volume.
set -euo pipefail

bucket="$1"
platform_volume="$2"
release=/var/lib/merlin/release

caddy_version=2.11.7
caddy_sha512=a7a433a1b133efc3c8d10eb0b99d52a24b5ef5c322dc77f5282182b1c0402139ab83f3a99f0c52409df77d20123fb0b523edad8a66d8f5e49136197bf61ef0e7

say() { echo "== $* =="; }

say "the release"
mkdir -p "$release"
# --exact-timestamps: two images differing in one setting can be exactly the same size, and a
# plain sync skips a file whose size matches.
aws s3 sync --delete --exact-timestamps --only-show-errors "s3://$bucket/artifacts/" "$release/"

say "the parent: nitro-cli, the allocator, gvproxy and the enclave's units"
# What enclave-runtime's deploy/ami would bake into an image, done here instead.
rpm -q aws-nitro-enclaves-cli jq >/dev/null 2>&1 || dnf -y -q install aws-nitro-enclaves-cli jq
# 2 vCPUs and 3 GiB for the enclave, the rest of the m6i.xlarge for the parent: the image is
# ~170 MiB and the runtime's heap sits beside it.
printf -- '---\nmemory_mib: 3072\ncpu_count: 2\n' > /etc/nitro_enclaves/allocator.yaml
install -m 0755 "$release/bin/gvproxy" /usr/local/bin/gvproxy
install -D -m 0644 "$release/host/units/gvproxy.yml" /etc/gvproxy/config.yml
install -m 0644 "$release/host/units/gvproxy.service" "$release/host/units/enclave.service" \
    /etc/systemd/system/
install -m 0755 "$release/host/units/enclave-start.sh" /usr/local/bin/enclave-start
mkdir -p /opt/enclave /etc/systemd/system/enclave.service.d
install -m 0644 "$release/eif/enclave.eif" "$release/eif/pcr.json" /opt/enclave/
# The runtime's unit names its own file; ours is enclave.eif.
printf '[Service]\nEnvironment=EIF=/opt/enclave/enclave.eif\n' \
    > /etc/systemd/system/enclave.service.d/merlin.conf

say "the platform volume"
# By volume id, not /dev/sdf: on a Nitro instance an EBS volume is an NVMe device whose name
# follows attachment order.
dev="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${platform_volume//-/}"
for _ in $(seq 30); do [[ -e "$dev" ]] && break; sleep 2; done
[[ -e "$dev" ]] || { echo "the platform volume $platform_volume is not attached" >&2; exit 1; }
# Formatted once, when blank. Never otherwise: it holds the platform's keys.
blkid "$dev" >/dev/null || mkfs.ext4 -q -L merlin-platform "$dev"
mkdir -p /srv/platform
uuid="$(blkid -s UUID -o value "$dev")"
grep -q "$uuid" /etc/fstab || echo "UUID=$uuid /srv/platform ext4 defaults,nofail 0 2" >> /etc/fstab
mountpoint -q /srv/platform || mount /srv/platform
id merlin >/dev/null 2>&1 || useradd --system --home-dir /srv/platform --shell /sbin/nologin merlin
chown merlin: /srv/platform
chmod 700 /srv/platform

say "the platform and caddy $caddy_version"
if [[ "$(/usr/local/bin/caddy version 2>/dev/null | cut -d' ' -f1)" != "v$caddy_version" ]]; then
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/caddy.tar.gz" \
        "https://github.com/caddyserver/caddy/releases/download/v$caddy_version/caddy_${caddy_version}_linux_amd64.tar.gz"
    echo "$caddy_sha512  $tmp/caddy.tar.gz" | sha512sum -c --quiet -
    tar -xzf "$tmp/caddy.tar.gz" -C "$tmp" caddy
    install -m 0755 "$tmp/caddy" /usr/local/bin/caddy
    rm -rf "$tmp"
fi
install -m 0755 "$release/bin/merlin-platform" /usr/local/bin/merlin-platform
install -m 0755 "$release/host/platform-start.sh" /usr/local/bin/merlin-platform-start
install -D -m 0644 "$release/host/platform.env" /etc/merlin/platform.env
install -m 0644 "$release/host/merlin-platform.service" "$release/host/caddy.service" \
    /etc/systemd/system/
# What the platform believes: this release's measurements. It reads the file again when it changes.
install -o merlin -m 0644 "$release/host/enclave-pins.json" /srv/platform/enclave-pins.json

say "restarting"
systemctl daemon-reload
systemctl enable nitro-enclaves-allocator.service gvproxy.service enclave.service \
    merlin-platform.service caddy.service
# The allocator takes its config only while no enclave holds its memory.
systemctl stop enclave.service
systemctl restart nitro-enclaves-allocator.service gvproxy.service
# Onto the new image. The store is in S3, so the enclave resumes where it was.
systemctl start enclave.service
systemctl restart merlin-platform.service caddy.service
systemctl --no-pager --lines=0 status enclave.service gvproxy.service merlin-platform.service \
    caddy.service || true

#!/usr/bin/env bash
# Tear the MutinyNet deployment down — the machine and everything that outlives it.
# A clean slate, not a pause: use ./down.sh to stop a running machine instead.
#
# Order is host before base: host reads base's state and attaches its volume, so
# base cannot go first. This removes the store buckets, the KMS key (a 7-day
# deletion window, recoverable until it lapses), the push application and the
# platform's treasury volume.
#
# The roots bucket is COMPLIANCE Object-Locked: S3 refuses to delete any object
# version still inside its retention (deployment.nix rootRetentionSecs, a day on
# MutinyNet) and nobody can shorten that — AWS support included. If base destroy
# stops on aws_s3_bucket.roots, the enclave wrote anchors within the last day:
# wait until a day past the last write and run this again.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_PROFILE=mpc-deployer AWS_REGION=us-east-1

read -rp 'This destroys the buckets, the KMS key and the platform treasury volume. Type "destroy mutinynet" to go on: ' reply
[[ "$reply" == "destroy mutinynet" ]] || { echo "aborted" >&2; exit 1; }

echo "== the machine (tofu/host) =="
tofu -chdir="$here/tofu/host" init -input=false
tofu -chdir="$here/tofu/host" destroy -auto-approve

echo "== what outlives machines (tofu/base) =="
tofu -chdir="$here/tofu/base" init -input=false
if ! tofu -chdir="$here/tofu/base" destroy -auto-approve; then
  cat >&2 <<'EOF'

base destroy did not finish. If it stopped on aws_s3_bucket.roots, the bucket
still holds anchor objects under COMPLIANCE lock — nothing can delete them until
their retention lapses (up to a day after the last write). Wait and re-run.
EOF
  exit 1
fi

cat >&2 <<'EOF'

Destroyed. These live outside tofu (written by deploy.sh and by hand), so they
remain — delete them for a total wipe; a new store uses a new fsId and new names:
  aws ssm delete-parameter --name /merlin/mutinynet/master-key/<fsId>
  aws ssm delete-parameter --name /merlin/mutinynet/platform/grid-client-id
  aws ssm delete-parameter --name /merlin/mutinynet/platform/grid-client-secret
EOF

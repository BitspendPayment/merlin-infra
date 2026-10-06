#!/usr/bin/env bash
# Stop MutinyNet. Stopped, it costs about $2.70 a month: its two disks.
#
# Sealed delegates and the platform's treasury run only while it is up; queued work resumes at the
# next start. The store is in S3 and the platform's on its own volume, so nothing is lost.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_PROFILE=mpc-deployer AWS_REGION=us-east-1

instance="$(tofu -chdir="$here/tofu/host" output -raw instance_id)"
aws ec2 stop-instances --instance-ids "$instance" >/dev/null
aws ec2 wait instance-stopped --instance-ids "$instance"
echo "stopped $instance"

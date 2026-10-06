#!/usr/bin/env bash
# Start MutinyNet and point its name at the address it came up on. About $0.20 an hour while up.
#
# There is no Elastic IP (it costs $3.60 a month whether the instance runs or not), so each start
# gets a new address and the name follows it. The enclave keeps its certificate in its store, so a
# start issues none; it serves a minute or two after the instance is running.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_PROFILE=mpc-deployer AWS_REGION=us-east-1
zone=Z0182614JSFDPB9F5ALY # vtxos.network
name=mutiny.vtxos.network

instance="$(tofu -chdir="$here/tofu/host" output -raw instance_id)"
aws ec2 start-instances --instance-ids "$instance" >/dev/null
aws ec2 wait instance-running --instance-ids "$instance"
ip="$(aws ec2 describe-instances --instance-ids "$instance" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
aws route53 change-resource-record-sets --hosted-zone-id "$zone" --change-batch "$(jq -n \
    --arg name "$name" --arg ip "$ip" \
    '{Changes: [{Action: "UPSERT", ResourceRecordSet:
        {Name: $name, Type: "A", TTL: 60, ResourceRecords: [{Value: $ip}]}}]}')" >/dev/null
echo "$name → $ip (instance $instance). ./down.sh when done."

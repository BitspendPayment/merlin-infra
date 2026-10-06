#!/usr/bin/env bash
# Ship a release to MutinyNet.
#
#   ./deploy.sh <tag>
#
# Takes the release CI published for <tag> (the enclave image, the cosigner, MerlinPlatform), then:
#   1. writes MutinyNet's settings into the cosigner, where the enclave measures them into PCR16;
#   2. locks the master key to the release's PCR0 and that PCR16, the first time — for good, with a
#      policy nobody can edit, which the enclave insists on — and afterwards checks it is locked to
#      this release: a new release needs a new key and store (README);
#   3. uploads the guest to where the image fetches it, ships the rest and installs it over SSM;
#   4. waits for the enclave to serve, and publishes the pins the app reads.
#
# The instance is stock Amazon Linux; the install sets the parent up as well (host/install.sh).
#
# Needs the instance up (./up.sh), gh, tofu, jq, python3, and the Grid sandbox view token in
# ~/.config/merlin/grid-sandbox.env (GRID_VIEW_ID, GRID_VIEW_SECRET).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_PROFILE=mpc-deployer AWS_REGION=us-east-1
tag="${1:?usage: deploy.sh <tag>}"
domain=mutiny.vtxos.network

say() { printf '\n== %s ==\n' "$*"; }
base() { tofu -chdir="$here/tofu/base" output -raw "$1"; }

bucket="$(base artifacts_bucket)"
roots="$(base roots_bucket)"
volume="$(base platform_volume_id)"
instance="$(tofu -chdir="$here/tofu/host" output -raw instance_id)"

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

say "release $tag"
gh release download "$tag" -R BitspendPayment/merlin-infra -D "$out/rel"
(cd "$out/rel" && sha256sum -c --quiet SHA256SUMS)
chmod +x "$out/rel/merlin-platform"
pcr0="$(jq -r .PCR0 "$out/rel/pcr.json")"

say "the cosigner's settings"
# Measured into PCR16 with its code, so a client sees which ASP and which services it talks to.
# The Grid token can only view: the cosigner fetches each payout's evidence from Grid itself.
# shellcheck source=/dev/null
source ~/.config/merlin/grid-sandbox.env
runtime_rev="$(git -C "$here" show "$tag:flake.lock" | jq -r '.nodes["enclave-runtime"].locked.rev')"
curl -fsSL -o "$out/guest-env.py" \
    "https://raw.githubusercontent.com/BitspendPayment/enclave-runtime/$runtime_rev/deploy/qemu-nitro/guest-env.py"
cp "$out/rel/cosigner.wasm" "$out/guest.wasm"
python3 "$out/guest-env.py" "$out/guest.wasm" \
    ASP_URL=https://mutinynet.arkade.sh \
    BITCOIN_NETWORK=mutinynet \
    "SERVICE_ORIGINS=$("$out/rel/merlin-platform" --print-identifier)=https://$domain:8443" \
    "SERVICE_CREDENTIALS_GRID=$GRID_VIEW_ID:$GRID_VIEW_SECRET" \
    SERVICE_CREDENTIAL_ORIGIN_GRID=https://api.lightspark.com
# PCR16 as the runtime extends it: once, with the component's SHA-256, from zero
# (nitro-attestation's guest_pcr; checked against `nitro-attest --measure`).
pcr16="$(python3 -c 'import hashlib,sys
d = hashlib.sha256(open(sys.argv[1], "rb").read()).digest()
print(hashlib.sha384(bytes(48) + d).hexdigest())' "$out/guest.wasm")"
echo "PCR0  $pcr0"
echo "PCR16 $pcr16"

say "the master key"
# The shape enclave-runtime's keys/policy.rs accepts: the account may read the key and delete it, the
# enclave's role may read it and, on this release's measurements, use it. Nobody may change it, so it
# is set with the lockout check bypassed, once.
key="$(base kms_key_arn)"
account="$(cut -d: -f5 <<<"$key")"
role="$(tofu -chdir="$here/tofu/host" output -raw role_arn)"
locked_to="$(aws kms get-key-policy --key-id "$key" --policy-name default --query Policy --output text \
    | jq -r '.Statement[] | select(.Sid == "ReleaseToTheEnclave") | .Condition.StringEqualsIgnoreCase
             | "\(."kms:RecipientAttestation:PCR0") \(."kms:RecipientAttestation:PCR16")"')"
if [[ -z "$locked_to" ]]; then
    policy="$(jq -n --arg account "$account" --arg role "$role" --arg pcr0 "$pcr0" --arg pcr16 "$pcr16" '
      {Version: "2012-10-17", Statement: [
        {Sid: "ReadAndDelete", Effect: "Allow",
         Principal: {AWS: "arn:aws:iam::\($account):root"},
         Action: ["kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus",
                  "kms:ListGrants", "kms:ListResourceTags", "kms:ScheduleKeyDeletion",
                  "kms:CancelKeyDeletion"],
         Resource: "*"},
        {Sid: "TheEnclaveReadsItsKey", Effect: "Allow", Principal: {AWS: $role},
         Action: ["kms:DescribeKey", "kms:GetKeyPolicy", "kms:ListGrants"], Resource: "*"},
        {Sid: "ReleaseToTheEnclave", Effect: "Allow", Principal: {AWS: $role},
         Action: ["kms:Decrypt", "kms:GenerateDataKey"], Resource: "*",
         Condition: {StringEqualsIgnoreCase: {
           "kms:RecipientAttestation:PCR0": $pcr0, "kms:RecipientAttestation:PCR16": $pcr16}}}
      ]}')"
    echo "This locks $key to this release, for good: nobody, you included, can change its policy"
    echo "again, and the only thing left to do with it is delete it."
    read -r -p "Type 'lock' to lock it: " answer
    [[ "$answer" == lock ]] || { echo "not locked; nothing shipped" >&2; exit 1; }
    aws kms put-key-policy --key-id "$key" --policy-name default \
        --bypass-policy-lockout-safety-check --policy "$policy"
elif [[ "$locked_to" != "$pcr0 $pcr16" ]]; then
    echo "$key is locked to another release (PCR0 ${locked_to:0:16}…). A new release needs a new key" >&2
    echo "and a fresh store: see the README." >&2
    exit 1
fi

say "shipping"
aws s3 cp --quiet "$out/guest.wasm" "s3://$roots/guest/guest.wasm"
mkdir -p "$out/art/eif" "$out/art/bin" "$out/art/host/units"
cp "$out/rel/enclave.eif" "$out/rel/pcr.json" "$out/art/eif/"
cp "$out/rel/merlin-platform" "$out/rel/gvproxy" "$out/art/bin/"
cp "$here"/host/* "$out/art/host/"
# The parent's side of the runtime, from the same commit as the image: gvproxy's address map and
# the units that start the enclave.
for unit in enclave.service enclave-start.sh gvproxy.service gvproxy.yml; do
    curl -fsSL -o "$out/art/host/units/$unit" \
        "https://raw.githubusercontent.com/BitspendPayment/enclave-runtime/$runtime_rev/deploy/ami/units/$unit"
done
# What the app and the platform believe. No trust_root: a real enclave is checked against AWS's.
jq -n --arg host "$domain" --arg pcr0 "$pcr0" --arg pcr16 "$pcr16" \
    --arg commit "$(git -C "$here" rev-list -n1 "$tag")" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{host: $host, pcr0: $pcr0, pcr16: $pcr16, rp_id: "vtxos.com",
      repo: "https://github.com/BitspendPayment/merlin-infra", commit: $commit,
      timestamp: $timestamp}' > "$out/art/host/enclave-pins.json"
aws s3 sync --delete --only-show-errors "$out/art/" "s3://$bucket/artifacts/"

say "installing on $instance"
command_id="$(aws ssm send-command \
    --instance-ids "$instance" \
    --document-name AWS-RunShellScript \
    --comment "merlin-infra $tag" \
    --parameters "commands=[\"aws s3 cp s3://$bucket/artifacts/host/install.sh /usr/local/sbin/merlin-install\",\"chmod 755 /usr/local/sbin/merlin-install\",\"/usr/local/sbin/merlin-install $bucket $volume\"]" \
    --timeout-seconds 1800 \
    --query Command.CommandId --output text)"
aws ssm wait command-executed --command-id "$command_id" --instance-id "$instance" || true
aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance" \
    --query '[Status, StandardOutputContent, StandardErrorContent]' --output text | tail -20

say "waiting for the enclave to serve"
for _ in $(seq 60); do
    # Any HTTP answer will do: it came over TLS with a certificate for the name, from the enclave.
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$domain/")" != 000 ]]; then
        aws s3 cp --quiet "$out/art/host/enclave-pins.json" "s3://$bucket/pins/deployment.json" \
            --content-type application/json --cache-control "no-cache, max-age=0"
        echo "serving https://$domain — pins published"
        exit 0
    fi
    sleep 10
done
echo "no answer from https://$domain after 10 minutes; the enclave's console:" >&2
echo "  aws ssm start-session --target $instance   then   journalctl -u enclave.service -n 100" >&2
exit 1

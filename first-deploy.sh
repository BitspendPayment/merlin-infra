#!/usr/bin/env bash
# Bring MutinyNet up from nothing — base, secrets, release and machine — in one run.
#
#   ./first-deploy.sh <tag>          # e.g. ./first-deploy.sh v3
#
# Use this after ./destroy.sh, or for the very first deployment. Every step is a no-op when it is
# already done, so if one fails (a slow release, a dropped connection) just run it again.
#
# It does the README's "First deployment": creates base, writes the new KMS key and push app into
# deployment.nix, loads the Firebase channel and the Grid tokens, tags the release and waits for CI
# to build it, brings the machine up, and ships. It pauses for you three times: each `tofu apply`
# shows its plan to confirm, and deploy.sh asks once to lock the master key to this release.
#
# Needs: OpenTofu, gh, jq, python3, the aws CLI, the Firebase service account at
# ~/.config/merlin/fcm-service-account.json and the Grid tokens at ~/.config/merlin/grid-sandbox.env.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
export AWS_PROFILE=mpc-deployer AWS_REGION=us-east-1
tag="${1:?usage: first-deploy.sh <tag>  (e.g. v3)}"
repo=BitspendPayment/merlin-infra

say()  { printf '\n== %s ==\n' "$*"; }
base() { tofu -chdir="$here/tofu/base" output -raw "$1"; }

for f in ~/.config/merlin/fcm-service-account.json ~/.config/merlin/grid-sandbox.env; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; exit 1; }
done
for c in tofu gh jq python3 aws; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done

say "base — buckets, KMS key, push app, platform volume (review the plan)"
tofu -chdir="$here/tofu/base" init -input=false
tofu -chdir="$here/tofu/base" apply

say "deployment.nix — the new key and push app"
kms="$(base kms_key_arn)"
push="$(base push_app_id)"
sed -i -E "s#^(  kmsKeyId = )\"[^\"]*\";#\1\"$kms\";#"  deployment.nix
sed -i -E "s#^(  pushAppId = )\"[^\"]*\";#\1\"$push\";#" deployment.nix
grep -q CHANGE-ME deployment.nix && { echo "kmsKeyId is still CHANGE-ME — base gave no key?" >&2; exit 1; }
echo "kmsKeyId=$kms  pushAppId=$push"

say "the push channel (Firebase)"
aws pinpoint update-gcm-channel --application-id "$push" \
    --gcm-channel-request "$(jq -n --rawfile s ~/.config/merlin/fcm-service-account.json \
        '{ServiceJson: $s, DefaultAuthenticationMethod: "TOKEN", Enabled: true}')" >/dev/null

say "the platform's Grid tokens"
# shellcheck source=/dev/null
source ~/.config/merlin/grid-sandbox.env
aws ssm put-parameter --overwrite --type SecureString \
    --name /merlin/mutinynet/platform/grid-client-id     --value "$GRID_CLIENT_ID"     >/dev/null
aws ssm put-parameter --overwrite --type SecureString \
    --name /merlin/mutinynet/platform/grid-client-secret --value "$GRID_CLIENT_SECRET" >/dev/null

say "release $tag"
if gh release view "$tag" -R "$repo" >/dev/null 2>&1; then
    echo "already published"
else
    # The tag carries the deployment.nix the image is built from; pushing it builds the release.
    git diff --quiet -- deployment.nix || \
        git commit -q -m "deployment: lock $tag to its key and push app" -- deployment.nix
    git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git tag "$tag"
    git push origin "$tag"
    sha="$(git rev-parse "$tag^{commit}")"
    echo "waiting for the release workflow…"
    sleep 8
    run="$(gh run list -R "$repo" --workflow release.yml --limit 30 \
           --json databaseId,headSha -q "map(select(.headSha==\"$sha\"))[0].databaseId" 2>/dev/null || true)"
    if [[ -n "$run" && "$run" != null ]]; then
        gh run watch "$run" -R "$repo" --exit-status
    else
        until gh release view "$tag" -R "$repo" >/dev/null 2>&1; do sleep 20; done
    fi
fi

say "the machine (review the plan)"
tofu -chdir="$here/tofu/host" init -input=false
tofu -chdir="$here/tofu/host" apply
"$here/up.sh"
"$here/deploy.sh" "$tag"

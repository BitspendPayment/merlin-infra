# merlin-infra

Merlin's MutinyNet deployment. The MerlinWallet cosigner runs in a **real AWS Nitro enclave**
(enclave-runtime's production image), and MerlinPlatform runs on the same machine, on an m6i.xlarge
in us-east-1 that is up only while it is needed.

```
phone ──https──▶ mutiny.vtxos.network:443  ──gvproxy──▶ Nitro enclave: enclave-runtime ▶ cosigner.wasm
      ──https──▶ mutiny.vtxos.network:8443 ──Caddy───▶ MerlinPlatform (on the parent, /srv/platform)
enclave ──▶ S3 (store), KMS (master key, released only to PCR0+PCR16), mutinynet.arkade.sh, Grid,
            the platform, AWS End User Messaging Push
```

**Test coins and Grid's sandbox only.** The platform has no authentication yet, and its keys sit on
a disk on the parent.

## Checking what runs

Each release's image is built by this repository's CI from public sources, so anyone can rebuild it
and compare:

```
nix build github:BitspendPayment/merlin-infra/<tag>#eif && jq -r .PCR0 result/pcr.json
```

The PCR0 published in the release notes must match. The image's settings are
[`deployment.nix`](deployment.nix): the buckets, the KMS key, the domain and the relying party.

The master key's policy is locked: `deploy.sh` sets it once, to the first release's PCR0 and PCR16,
with no permission to change it, and the enclave refuses to use a key whose policy anybody could
change (enclave-runtime's `keys/policy.rs`). KMS releases the master secret to that PCR0 and PCR16
and to nothing else. The account can still read the key and delete it: an attacker can stop the
enclave, but cannot read the secret.

PCR16 measures the cosigner together with its settings. It cannot be reproduced from here alone,
because one of the settings is the Grid sandbox view token.

## Cost

| | |
|---|---|
| Stopped | about $2.70 a month: the 32 GB root disk and the 1 GB platform volume |
| Up | about $0.20 an hour: m6i.xlarge $0.192 plus its public IPv4 |
| One hour a day | about $8.70 a month |

There is no Elastic IP. Each start gets a new address, and `up.sh` points the name at it.

## Layout

| | |
|---|---|
| `deployment.nix` | what enclave-runtime's `mkEif` bakes into the image (its PCR0) |
| `flake.nix`, `flake.lock` | the image, from the runtime commit the lock pins |
| `pins.env` | the MerlinWallet and MerlinPlatform commits a release builds from |
| `.github/workflows/release.yml` | on a `v*` tag: enclave.eif + pcr.json, gvproxy, cosigner.wasm, merlin-platform |
| `tofu/base` | what outlives machines: the store buckets (roots under Object Lock), the KMS key, the push application, the platform volume, the artifacts and pins bucket |
| `tofu/host` | the machine: enclave-runtime's `deploy/tofu`, plus the platform's ports and volume, and the role's extra grants |
| `host/` | what `deploy.sh` installs on the parent. `install.sh` also sets a stock Amazon Linux 2023 instance up as a Nitro parent: nitro-cli, the allocator, gvproxy and the runtime's units, from the commit `flake.lock` pins |
| `deploy.sh <tag>` | ships a release |
| `up.sh`, `down.sh` | start and stop |

## Day to day

```
./up.sh                 # start; serving a minute or two later
./down.sh               # stop
```

### A new release is a new store

The key is locked to one PCR0 and one PCR16, so a release that changes either can never open the
store the old one made. That covers a new runtime, a new cosigner, and new cosigner settings. Until
the runtime can hand its secret to an approved successor, a new release starts fresh: MutinyNet
wallets on the old store are left behind.

1. A new key: `tofu -chdir=tofu/base apply -replace=aws_kms_key.master`. The old one is scheduled
   for deletion, which its policy still allows.
2. In `deployment.nix`: the new `kmsKeyId`, a new `fsId` (`openssl rand -hex 16`), and the same
   value at the end of `masterKeyParameter`.
3. Bump `pins.env` (and `flake.lock` for a new runtime), commit, tag `vN`, push the tag, wait for
   the release, then `./deploy.sh vN`. It locks the new key to the new release.

## First deployment

You need: `export AWS_PROFILE=mpc-deployer` (account 639920118099; the default profile on the
deploying machine is a different account, which the tofu refuses), OpenTofu ≥ 1.10, gh, jq, python3, the Grid sandbox tokens in `~/.config/merlin/grid-sandbox.env`, and the Firebase service
account at `~/.config/merlin/fcm-service-account.json`.

1. **What outlives machines.**

   ```
   tofu -chdir=tofu/base init && tofu -chdir=tofu/base apply
   ```

   Put `tofu output kms_key_arn` and `push_app_id` into `deployment.nix` (`kmsKeyId`, `pushAppId`).

2. **The push channel**, loaded once from the CLI so the Firebase key never reaches tofu state or
   an image. `TOKEN`, because the default legacy key is switched off and the enclave refuses a
   channel that would use it:

   ```
   aws pinpoint update-gcm-channel --application-id "$(tofu -chdir=tofu/base output -raw push_app_id)" \
       --gcm-channel-request "$(jq -n --rawfile s ~/.config/merlin/fcm-service-account.json \
           '{ServiceJson: $s, DefaultAuthenticationMethod: "TOKEN", Enabled: true}')"
   ```

3. **The platform's Grid token**, as SecureStrings. The platform reads them at each start:

   ```
   source ~/.config/merlin/grid-sandbox.env
   aws ssm put-parameter --type SecureString --name /merlin/mutinynet/platform/grid-client-id --value "$GRID_CLIENT_ID"
   aws ssm put-parameter --type SecureString --name /merlin/mutinynet/platform/grid-client-secret --value "$GRID_CLIENT_SECRET"
   ```

4. **A release.** `nix flake lock`, commit, `git tag v1 && git push origin main v1`, and wait for
   the Release workflow.

5. **The machine.**

   ```
   tofu -chdir=tofu/host init && tofu -chdir=tofu/host apply
   ./up.sh                                       # the name → its address
   ./deploy.sh v1
   ```

   Give the new instance a minute or two before `deploy.sh`, so that its SSM agent has registered.
   The first install also sets up the parent (a few minutes of `dnf`).

   The first enclave boot is a genesis. KMS mints the master secret, it is sealed into SSM, and the enclave
   takes a Let's Encrypt certificate. A failing first boot can be retried. The certificate is kept
   in the store, but each fresh genesis asks Let's Encrypt again, and it allows five certificates
   for one name a week.

6. **Check it.** From a checkout of enclave-runtime at the locked commit:

   ```
   cargo run -p nitro-attestation --features cli --bin nitro-attest -- \
       --url https://mutiny.vtxos.network/auth/ --pcr0 <PCR0> --pcr16 <PCR16>
   ```

## Not verified yet

This is the first deployment of enclave-runtime on Nitro hardware (see its README, "Limits"). None
of these has run on hardware yet: the metadata service through gvproxy, AWS-signed receipts, the
PTP clock, KMS recipient release, CloudWatch delivery and push.

Sealed delegates and the platform's treasury run only while the machine is up. This works only if
MutinyNet's VTXOs outlive the time it spends stopped.

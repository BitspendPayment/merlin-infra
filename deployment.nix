# MutinyNet's enclave image: what `mkEif` bakes into it, in enclave-runtime's
# deploy/nix/deployment.nix shape. Every value is measured into PCR0, so changing
# any of them is a new image, new pins and a new key policy (`deploy.sh` does all
# three). None of it is secret.
{
  # Created by tofu/. Object Lock holds the anchor chain, boot records, the guest
  # and the sealed ACME cache. The pool's own bytes live on the EBS volume
  # tofu/host sizes with pool_size_gib — v2 has no data bucket.
  rootsBucket = "merlin-mutinynet-roots";

  # A fresh v2 namespace in the roots bucket. The old v1 store's anchors sit under
  # the empty prefix, and a v2 runtime refuses that store (one pool, not one per
  # tenant) rather than touching it — so v2 genesis lives under its own prefix.
  # See enclave-runtime docs/COMPATIBILITY.md.
  bucketPrefix = "v2/";

  # The filesystem's HKDF salt. Fixed for the life of the store: a new one is a
  # new, empty filesystem. Fresh for the v2 store.
  fsId = "ce3d1d8269b3991800282eab8cbbf6c7";

  region = "us-east-1";

  # The key the master secret is minted under (`tofu output kms_key_arn`), and
  # where it is kept sealed, one parameter per store. deploy.sh locks the key to
  # the first release it ships, for good; a new release needs a new key, a new
  # fsId and so a fresh store (README). v2 changes PCR0, so the old key will not
  # release — mint a fresh one before deploying:
  #   tofu -chdir=tofu/base apply -replace=aws_kms_key.master
  # then paste `tofu -chdir=tofu/base output kms_key_arn` in here.
  kmsKeyId = "CHANGE-ME-after-kms-replace";
  masterKeyParameter = "/merlin/mutinynet/master-key/ce3d1d8269b3991800282eab8cbbf6c7";

  # Test coins: root records stay locked for a day, not ten years, so the
  # buckets can be retired. Production says ten years.
  rootRetentionSecs = 86400;

  tlsDomains = [ "mutiny.vtxos.network" ];

  # Passkeys for vtxos.com, whose assetlinks.json names com.vtxos.app. The app
  # claims its signing key's hash as its origin: the debug keystore
  # (2D:FD:50:23…) and the release key (BB:5A:4D:7A…).
  rpId = "vtxos.com";
  webauthnAllowedOrigins = [
    "android:apk-key-hash:Lf1QIwQnlPBYPwDFhloUkYC-0tYAKSpKCQbEiyz118s"
    "android:apk-key-hash:u1pNepeObJUpSkSqH964HvFRqbhC_ejQP3GHA3-lreI"
  ];

  # The runtime module names it "/${name_prefix}-${environment}/guest".
  guestLogGroup = "/merlin-mutinynet/guest";

  # `tofu output push_app_id`.
  pushAppId = "cce7d19f815242c1879d323f11c0bc85";
}

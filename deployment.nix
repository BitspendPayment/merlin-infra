# MutinyNet's enclave image: what `mkEif` bakes into it, in enclave-runtime's
# deploy/nix/deployment.nix shape. Every value is measured into PCR0, so changing
# any of them is a new image, new pins and a new key policy (`deploy.sh` does all
# three). None of it is secret.
{
  # Created by tofu/. The roots bucket has Object Lock; the data bucket does not,
  # so dead copy-on-write blocks stay reclaimable.
  dataBucket = "merlin-mutinynet-data";
  rootsBucket = "merlin-mutinynet-roots";
  bucketPrefix = "";

  # The filesystem's HKDF salt. Fixed for the life of the store: a new one is a
  # new, empty filesystem.
  fsId = "d2eefdf457df42df7a068d9c178e85cc";

  region = "us-east-1";

  # The key the master secret is minted under (`tofu output kms_key_arn`), and
  # where it is kept sealed, one parameter per store. deploy.sh locks the key to
  # the first release it ships, for good; a new release needs a new key, a new
  # fsId and so a fresh store (README).
  kmsKeyId = "arn:aws:kms:us-east-1:639920118099:key/96489c16-422a-4c8e-a8a8-761f9717aca2";
  masterKeyParameter = "/merlin/mutinynet/master-key/d2eefdf457df42df7a068d9c178e85cc";

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
  guestLogStream = "guest";

  guestObject = "guest/guest.wasm";

  # The cosigner runs sealed delegates from background tasks.
  backgroundTasks = true;
  backgroundConcurrency = 1;

  # `tofu output push_app_id`.
  pushAppId = "cce7d19f815242c1879d323f11c0bc85";
}

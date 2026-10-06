{
  description = "Merlin's MutinyNet deployment: its enclave image, reproducibly";

  # The image is enclave-runtime's production EIF with this repository's
  # deployment.nix baked in. flake.lock pins the runtime, so a tag here names one
  # PCR0 that anyone can rebuild:
  #
  #   nix build .#eif && jq -r .PCR0 result/pcr.json
  inputs.enclave-runtime.url = "github:BitspendPayment/enclave-runtime";

  outputs = { self, enclave-runtime }:
    let
      runtime = enclave-runtime.packages.x86_64-linux;
    in
    {
      packages.x86_64-linux = {
        eif = enclave-runtime.lib.x86_64-linux.mkEif (import ./deployment.nix);
        # What deploy.sh measures the guest with, and what the AMI runs beside the EIF.
        inherit (runtime) nitro-attest gvproxy;
      };
    };
}

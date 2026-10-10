# The MutinyNet machine: enclave-runtime's Nitro parent (its deploy/tofu, used as
# it is), with MerlinPlatform beside the enclave. The master key's policy is not
# here: deploy.sh locks it once, for good, which is not state to manage.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket       = "vtxos-tofu-state"
    key          = "merlin-infra/mutinynet/host.tfstate"
    region       = "us-east-1"
    profile      = "mpc-deployer"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region              = "us-east-1"
  profile             = "mpc-deployer"
  allowed_account_ids = ["639920118099"]
  default_tags {
    tags = { Project = "merlin", Stack = "mutinynet" }
  }
}

data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket  = "vtxos-tofu-state"
    key     = "merlin-infra/mutinynet/base.tfstate"
    region  = "us-east-1"
    profile = "mpc-deployer"
  }
}

data "aws_caller_identity" "current" {}

locals {
  # Stock Amazon Linux 2023 (al2023-ami-2023.12.20260930.0-kernel-6.18), pinned:
  # a new AMI replaces the instance, so it changes when someone means it to. No
  # baked image — deploy.sh's install sets the parent up (host/install.sh).
  ami = "ami-0d27e0fb3bac4d724"

  base    = data.terraform_remote_state.base.outputs
  account = data.aws_caller_identity.current.account_id
}

# =============================================================================
# The parent instance
# =============================================================================

# The ref is the enclave-runtime commit flake.lock pins: the parent units and the
# EIF's expectations of its parent (gvproxy's address map, IMDS hop limit) come
# from the same tree.
module "enclave" {
  source = "git::https://github.com/BitspendPayment/enclave-runtime.git//deploy/tofu?ref=c2ea60ea573ba294cd9a807a9bf3b174d78e7378"

  aws_profile       = "mpc-deployer"
  region            = "us-east-1"
  name_prefix       = "merlin"
  environment       = "mutinynet"
  ami_id            = local.ami
  instance_type     = "c6i.xlarge"
  availability_zone = local.base.availability_zone
  roots_bucket      = local.base.roots_bucket
  push_app_id       = local.base.push_app_id

  # v2 keeps the whole pool on one fixed EBS volume (no data bucket). 32 GiB cut
  # into 200 MiB regions is ~160 tenants; region 0 is the control pool. Raise it
  # to lift the tenant cap — it cannot grow after genesis.
  pool_size_gib = 32

  # MerlinPlatform on :8443 behind Caddy, which takes its certificate over HTTP-01
  # on :80 — :443 is the enclave's.
  extra_ingress_ports = [80, 8443]
}

resource "aws_volume_attachment" "platform" {
  device_name = "/dev/sdf"
  volume_id   = local.base.platform_volume_id
  instance_id = module.enclave.instance_id
}

# =============================================================================
# What the role may do beyond the module's grants
# =============================================================================

data "aws_iam_policy_document" "merlin" {
  # Where the sealed master secret is kept, one per store (deployment.nix
  # `masterKeyParameter`): written once, at genesis, and read at every boot.
  # Only KMS ciphertext ever goes there.
  statement {
    sid       = "MasterKeyParameter"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = ["arn:aws:ssm:us-east-1:${local.account}:parameter/merlin/mutinynet/master-key/*"]
  }
  # The platform's Grid token, put by hand as a SecureString (README).
  statement {
    sid       = "PlatformSecrets"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:us-east-1:${local.account}:parameter/merlin/mutinynet/platform/*"]
  }
  statement {
    sid       = "ListArtifacts"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.base.artifacts_bucket}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["artifacts/*"]
    }
  }
  statement {
    sid       = "ReadArtifacts"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${local.base.artifacts_bucket}/artifacts/*"]
  }
}

resource "aws_iam_role_policy" "merlin" {
  name   = "merlin"
  role   = module.enclave.role_name
  policy = data.aws_iam_policy_document.merlin.json
}

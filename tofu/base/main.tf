# What MutinyNet keeps across machines: the enclave's store, the key its master
# secret is minted under, the push application, the platform's volume, and the
# bucket deploys and pins go through.
#
# Applied once, before any image exists, because deployment.nix names these
# (the buckets, the key's ARN, the push application) and those names are
# measured into PCR0. The machine is tofu/host, in its own state, so destroying
# a host never comes near the store.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  # vtxos-tofu-state is created by hand once per account (see the README).
  backend "s3" {
    bucket       = "vtxos-tofu-state"
    key          = "merlin-infra/mutinynet/base.tfstate"
    region       = "us-east-1"
    profile      = "mpc-deployer"
    encrypt      = true
    use_lockfile = true
  }
}

# The profile is named, and the account pinned, because this machine's default
# profile is a different account.
provider "aws" {
  region              = "us-east-1"
  profile             = "mpc-deployer"
  allowed_account_ids = ["639920118099"]
  default_tags {
    tags = { Project = "merlin", Stack = "mutinynet" }
  }
}

locals {
  name = "merlin-mutinynet"
  # The instance's zone: the platform volume must be in it. tofu/host passes the
  # same zone to the runtime module.
  availability_zone = "us-east-1a"
}

# =============================================================================
# The enclave's store
# =============================================================================

# Slabs. Unlocked, so dead copy-on-write blocks can be reclaimed.
resource "aws_s3_bucket" "data" {
  bucket        = "${local.name}-data"
  force_destroy = true
}

# Root records, locked by the runtime itself (COMPLIANCE, rootRetentionSecs in
# deployment.nix: a day here). No default retention: what is locked, and for how
# long, is the image's decision and so is measured. force_destroy cannot remove a
# version still under retention; once the last one lapses it can.
resource "aws_s3_bucket" "roots" {
  bucket              = "${local.name}-roots"
  object_lock_enabled = true
  force_destroy       = true
}

resource "aws_s3_bucket_versioning" "roots" {
  bucket = aws_s3_bucket.roots.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "store" {
  for_each                = { data = aws_s3_bucket.data.id, roots = aws_s3_bucket.roots.id }
  bucket                  = each.value
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# =============================================================================
# The master key
# =============================================================================

# Locked by deploy.sh to one release's PCR0 and PCR16, with a policy nobody can
# edit afterwards — the enclave refuses any other (enclave-runtime's
# keys/policy.rs). Until then the default policy stands, and no secret exists:
# the enclave mints one only under a locked key. A new release needs a new key
# (`tofu apply -replace=aws_kms_key.master`, README); the old one can still be
# scheduled for deletion, the one thing its policy leaves the account.
resource "aws_kms_key" "master" {
  description             = "${local.name}: the enclave's master secret, released only to one PCR0 and PCR16"
  deletion_window_in_days = 7
  lifecycle {
    ignore_changes = [policy]
  }
}

# =============================================================================
# Wakes
# =============================================================================

# AWS End User Messaging Push. Its FCM channel, which holds the Firebase service
# account, is loaded once from the CLI (README), so the key never reaches tofu
# state or an image.
resource "aws_pinpoint_app" "push" {
  name = "${local.name}-wakes"
}

# =============================================================================
# The platform's disk
# =============================================================================

# MerlinPlatform's store, its half of every escrow key and its payout key. Its own
# volume, so a new instance — a new AMI, a resize — keeps them.
resource "aws_ebs_volume" "platform" {
  availability_zone = local.availability_zone
  size              = 1
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "${local.name}-platform" }
}

# =============================================================================
# Artifacts in, pins out
# =============================================================================

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${local.name}-artifacts"
  force_destroy = true
}

# Public policies allowed, ACLs not: the only public thing is pins/.
resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

# The app fetches the pins before it has any identity to authenticate with.
resource "aws_s3_bucket_policy" "pins_public" {
  bucket     = aws_s3_bucket.artifacts.id
  depends_on = [aws_s3_bucket_public_access_block.artifacts]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicPins"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.artifacts.arn}/pins/*"
    }]
  })
}

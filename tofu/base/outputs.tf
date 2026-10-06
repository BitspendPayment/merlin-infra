output "data_bucket" {
  value = aws_s3_bucket.data.id
}

output "roots_bucket" {
  value = aws_s3_bucket.roots.id
}

# deployment.nix `kmsKeyId`.
output "kms_key_arn" {
  value = aws_kms_key.master.arn
}

# deployment.nix `pushAppId`.
output "push_app_id" {
  value = aws_pinpoint_app.push.application_id
}

output "platform_volume_id" {
  value = aws_ebs_volume.platform.id
}

output "availability_zone" {
  value = local.availability_zone
}

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.id
}

output "pins_url" {
  value = "https://${aws_s3_bucket.artifacts.bucket_regional_domain_name}/pins/deployment.json"
}

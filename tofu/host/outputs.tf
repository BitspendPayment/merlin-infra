output "instance_id" {
  value = module.enclave.instance_id
}

# Changes on every start (no Elastic IP): up.sh points the name at it.
output "public_ip" {
  value = module.enclave.public_ip
}

# The key policy deploy.sh locks names it.
output "role_arn" {
  value = module.enclave.role_arn
}

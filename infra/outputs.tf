output "instance_public_ip" {
  description = "Public IP of the Mjolnir instance"
  value       = oci_core_instance.mjolnir.public_ip
}

output "instance_id" {
  description = "OCID of the Mjolnir instance"
  value       = oci_core_instance.mjolnir.id
}

output "ssh_command" {
  description = "SSH command to connect via public IP"
  value       = "ssh opc@${oci_core_instance.mjolnir.public_ip}"
}

output "ssh_tailscale" {
  description = "SSH command via Tailscale (after tailscale up)"
  value       = "ssh opc@mjolnir"
}

output "availability_domain" {
  description = "Availability domain of the instance"
  value       = oci_core_instance.mjolnir.availability_domain
}

variable "tenancy_ocid" {
  description = "OCID of the OCI tenancy"
  type        = string
}

variable "user_ocid" {
  description = "OCID of the OCI user"
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint of the OCI API signing key"
  type        = string
}

variable "private_key_path" {
  description = "Path to the OCI API private key"
  type        = string
  default     = "~/.oci/oci_api_key.pem"
}

variable "compartment_ocid" {
  description = "OCID of the compartment to create resources in"
  type        = string
}

variable "region" {
  description = "OCI region"
  type        = string
  default     = "eu-paris-1"
}

variable "ssh_public_key" {
  description = "SSH public key for instance access"
  type        = string
}

variable "instance_shape" {
  description = "Instance shape (Always Free: VM.Standard.A1.Flex)"
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "instance_ocpus" {
  description = "Number of OCPUs (Always Free allows up to 4)"
  type        = number
  default     = 4
}

variable "instance_memory_gb" {
  description = "Memory in GB (Always Free allows up to 24)"
  type        = number
  default     = 24
}

variable "boot_volume_gb" {
  description = "Boot volume size in GB (Always Free: up to 200 total)"
  type        = number
  default     = 50
}

variable "github_repo_url" {
  description = "GitHub repo URL for cloning mjolnir onto the instance"
  type        = string
  default     = ""
}

variable "tailscale_auth_key" {
  description = "Tailscale auth key (from https://login.tailscale.com/admin/settings/keys). Use a reusable key."
  type        = string
  sensitive   = true
  default     = ""
}

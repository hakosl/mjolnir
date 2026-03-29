terraform {
  required_version = ">= 1.5"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# --- Networking ---

resource "oci_core_vcn" "mjolnir" {
  compartment_id = var.compartment_ocid
  display_name   = "mjolnir-vcn"
  cidr_blocks    = ["10.0.0.0/16"]
  dns_label      = "mjolnir"
}

resource "oci_core_internet_gateway" "mjolnir" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.mjolnir.id
  display_name   = "mjolnir-igw"
  enabled        = true
}

resource "oci_core_route_table" "mjolnir" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.mjolnir.id
  display_name   = "mjolnir-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.mjolnir.id
  }
}

resource "oci_core_security_list" "mjolnir" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.mjolnir.id
  display_name   = "mjolnir-sl"

  # Egress: allow all outbound
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }

  # Ingress: SSH
  ingress_security_rules {
    protocol  = "6" # TCP
    source    = "0.0.0.0/0"
    stateless = false

    tcp_options {
      min = 22
      max = 22
    }
  }

  # Ingress: ICMP (ping)
  ingress_security_rules {
    protocol  = "1" # ICMP
    source    = "0.0.0.0/0"
    stateless = false
  }
}

resource "oci_core_subnet" "mjolnir" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.mjolnir.id
  display_name               = "mjolnir-subnet"
  cidr_block                 = "10.0.1.0/24"
  route_table_id             = oci_core_route_table.mjolnir.id
  security_list_ids          = [oci_core_security_list.mjolnir.id]
  prohibit_public_ip_on_vnic = false
  dns_label                  = "mjolnir"
}

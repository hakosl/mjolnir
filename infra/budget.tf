# Budget alert: max $5/month with notifications at 80% and 100%

resource "oci_budget_budget" "mjolnir" {
  compartment_id = var.tenancy_ocid
  amount         = 5
  reset_period   = "MONTHLY"
  display_name   = "mjolnir-budget"
  description    = "Mjolnir spending limit - max $5 USD/month"
  target_type    = "COMPARTMENT"
  targets        = [var.compartment_ocid]
}

resource "oci_budget_alert_rule" "warning" {
  budget_id      = oci_budget_budget.mjolnir.id
  display_name   = "mjolnir-80pct-warning"
  type           = "ACTUAL"
  threshold      = 80
  threshold_type = "PERCENTAGE"
  message        = "Mjolnir OCI spending has reached 80% of $5 monthly budget ($4.00)"
  recipients     = var.alert_email
}

resource "oci_budget_alert_rule" "critical" {
  budget_id      = oci_budget_budget.mjolnir.id
  display_name   = "mjolnir-100pct-limit"
  type           = "ACTUAL"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  message        = "Mjolnir OCI spending has reached $5 monthly budget limit!"
  recipients     = var.alert_email
}

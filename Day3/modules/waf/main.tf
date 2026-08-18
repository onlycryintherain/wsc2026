# WAF is managed by bastion_setup.sh via AWS CLI after infrastructure creation.
# Terraform provider has limitations with deeply nested WAF rules (NotStatement + OrStatement).
# See: scripts/bastion_setup.sh "Configuring WAF custom rules" section.

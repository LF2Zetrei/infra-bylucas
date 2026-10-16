output "root_domain" {
  description = "Domaine racine configuré"
  value       = ovh_domain_zone_record.root.zone
}

output "vps_ip" {
  description = "IP pointée par le domaine et le wildcard"
  value       = var.vps_ip
}

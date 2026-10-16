variable "domain_name" {
  description = "Nom de domaine géré (ex: bylucas.com), acheté manuellement chez OVH"
  type        = string
}

variable "vps_ip" {
  description = "Adresse IP publique du VPS, obtenue après création manuelle sur l'espace client OVH"
  type        = string
}

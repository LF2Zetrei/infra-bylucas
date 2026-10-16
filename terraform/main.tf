terraform {
  required_version = ">= 1.5"

  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "~> 0.44"
    }
  }
}

# Le provider lit automatiquement ces 4 variables d'environnement au démarrage,
# sans qu'on ait besoin de les référencer ici :
#   OVH_ENDPOINT, OVH_APPLICATION_KEY, OVH_APPLICATION_SECRET, OVH_CONSUMER_KEY
# Bloc vide intentionnellement : tout passe par l'environnement, jamais par le code.
provider "ovh" {}

# --- Enregistrement A pour le domaine racine (ex: bylucas.com -> IP du VPS) ---
resource "ovh_domain_zone_record" "root" {
  zone      = var.domain_name
  subdomain = ""
  fieldtype = "A"
  ttl       = 3600
  target    = var.vps_ip
}

# --- Enregistrement A wildcard pour tous les sous-domaines (*.bylucas.com) ---
resource "ovh_domain_zone_record" "wildcard" {
  zone      = var.domain_name
  subdomain = "*"
  fieldtype = "A"
  ttl       = 3600
  target    = var.vps_ip
}

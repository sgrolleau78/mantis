#!/usr/bin/env bash
set -euo pipefail

echo "
********************************************************
Etape 1 : Pré requis
Installation Docker Engine + compose-plugin (officiel)
********************************************************"

echo ">>> Step [1] Mise à jour de la liste des paquets..."

sudo apt-get update

# Installation de 3 paquets :
# ca-certificates - autorités de certification racines
# curl - utilitaire de téléchargement
# gnupg - cryptographie et gestion de clés GPG
echo "********************************************************"
echo ">>> Step [2] Installation ou mise à jour des paquets ca-certificates, curl, gnupg"

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg

# Création du répertoire des clés GPG
echo "********************************************************"
echo ">>> Step [3] Création du répertoire des clés GPG"

sudo install -m 0755 -d /etc/apt/keyrings

echo "********************************************************"
echo ">>> Step [4] Téléchargement et vérification de la clé publique Docker"

if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
   | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Ajout du dépôt officiel Docker
echo "********************************************************"
echo ">>> Step [5] Ajout du dépôt officiel Docker"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
 | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Mise à jour avec le nouveau dépot Docker
echo "********************************************************"
echo ">>> Step [6] Mise à jour avec le nouveau dépot Docker"

sudo apt-get update

# Installation de Docker et Docker Compose
echo "********************************************************"
echo ">>> Step [7] Installation de Docker"

if ! command -v docker >/dev/null 2>&1; then
  echo ">>> Installation de Docker..."
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
                         docker-buildx-plugin docker-compose-plugin
else
  echo ">>> Docker est déjà installé."
fi

# Ajout de l'utilisateur au groupe docker
echo "********************************************************"
echo ">>> Step [8] Ajout de l'utilisateur au groupe docker"

sudo usermod -aG docker "$USER"
echo ">>> Utilisateur ajouté au groupe docker."
echo ">>> NOTE: le changement de groupe ne sera actif dans un shell interactif"
echo ">>>       qu'après reconnexion (ou 'newgrp docker'). Ce script utilise"
echo ">>>       'sudo docker compose' pour ne pas dépendre de ce rechargement."

echo "
********************************************************
Etape 2 : Création d'un swapfile (8 Go)
Permet d'éviter les erreurs OOM avec seulement 8 Go de RAM
********************************************************"

echo ">>> Step [1] Vérifie si un swapfile existe déjà"
CREATE_SWAP=1
if [ -f /swapfile ]; then
  SIZE=$(sudo du -m /swapfile | cut -f1)
  if [ "$SIZE" -lt 8192 ]; then
    echo ">>> /swapfile existe mais est trop petit, recréation..."
    sudo swapoff /swapfile || true
    sudo rm /swapfile
    CREATE_SWAP=1
  else
    echo ">>> /swapfile de taille correcte déjà présent."
    CREATE_SWAP=0
  fi
fi

if [ "$CREATE_SWAP" -eq 1 ]; then
  echo ">>> Création du swapfile de 8G..."

  if sudo fallocate -l 8G /swapfile 2>/dev/null; then
    echo ">>> Swapfile créé avec fallocate (rapide)."
  else
    echo ">>> fallocate non disponible, utilisation de dd (plus long)..."
    sudo dd if=/dev/zero of=/swapfile bs=1M count=8192 status=progress
  fi

  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
fi

echo "********************************************************"
echo ">>> Step [2] Active le swapfile"

if [ "$CREATE_SWAP" -eq 1 ]; then
    sudo swapon /swapfile
    echo ">>> Swapfile activé."
else
    echo ">>> Swapfile déjà actif ou taille correcte, pas de modification."
fi

echo "********************************************************"
echo ">>> Step [3] Vérifie si la ligne est déjà dans /etc/fstab, sinon l'ajoute"
if ! grep -q '^/swapfile' /etc/fstab; then
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
  echo ">>> /etc/fstab mis à jour pour activer le swap au démarrage."
else
  echo ">>> Entrée déjà présente dans /etc/fstab."
fi

echo "********************************************************"
echo ">>> Step [4] Vérification finale"
echo ">>> Vérification du swap activé :"
swapon --show
free -h

echo "
********************************************************
Etape 3 : Création du projet et git init
********************************************************"
echo ">>> Step [1] création du répertoire ~/mantis-bt "
mkdir -p ~/mantis-bt && cd ~/mantis-bt

if [ ! -d ".git" ]; then
  git init
fi

echo ">>> Step [1bis] Préparation des dossiers de volumes (droits corrects)"
mkdir -p ./config ./custom ./mysql

echo "********************************************************"
echo ">>> Step [2] Génération du fichier .env (mots de passe)"

if [ ! -f .env ]; then
  MYSQL_ROOT_PASSWORD=$(openssl rand -base64 24)
  MYSQL_PASSWORD=$(openssl rand -base64 24)
  cat <<EOF > .env
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_DATABASE=bugtracker
MYSQL_USER=mantisbt
MYSQL_PASSWORD=${MYSQL_PASSWORD}
EOF
  chmod 600 .env
  echo ">>> .env généré avec des mots de passe aléatoires."
else
  echo ">>> .env déjà présent, conservé tel quel."
fi

if [ ! -f .gitignore ]; then
  echo ".env" > .gitignore
fi

echo "********************************************************"
echo ">>> Step [3] Création du fichier docker-compose.yml avec image MantisBT + MariaDB"

cat <<'EOF' | tee docker-compose.yml > /dev/null
services:
  mantisbt:
    image: xlrl/mantisbt:latest
    environment:
      MANTIS_TIMEZONE: Europe/Berlin
      # IMPORTANT: mis à 1 pour pouvoir lancer l'assistant d'installation web
      # (http://127.0.0.1:8989/admin/install.php). Une fois l'installation
      # terminée, repasser à 0 et relancer "sudo docker compose up -d".
      MANTIS_ENABLE_ADMIN: 1
    ports:
      - "127.0.0.1:8989:80"
    depends_on:
      mysql:
        condition: service_healthy
    volumes:
      - ./config:/var/www/html/config
      - ./custom:/var/www/html/custom
    restart: always

  mysql:
    image: mariadb:latest
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - ./mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 10
    restart: always
EOF
echo ">>> docker-compose.yml généré."

echo "********************************************************"
echo ">>> Step [4] Démarrage des conteneurs MantisBT et MariaDB"

sudo docker compose up -d

echo "********************************************************"
echo ">>> Step [5] Pause pour laisser le temps aux services de démarrer"

sleep 15

if ! sudo docker compose ps --status running | grep -q "mantisbt"; then
  echo "[ERREUR] Les conteneurs ne semblent pas avoir démarré correctement."
  sudo docker compose logs
  exit 1
fi

echo ""
echo "********************************************************"
echo ">>> Installation terminée."
echo "********************************************************"
echo ">>> MantisBT est démarré. Accessible en local sur http://127.0.0.1:8989"
echo ">>> (accès distant : passer par un reverse proxy/VPN, le port n'est pas exposé publiquement)"
echo ""
echo ">>> PROCHAINE ÉTAPE - Assistant d'installation web :"
echo ">>>   1) Ouvrir : http://127.0.0.1:8989/admin/install.php"
echo ">>>      (tunnel SSH si serveur distant : ssh -L 8989:127.0.0.1:8989 user@serveur)"
echo ">>>   2) Renseigner les identifiants DB (visibles dans ~/mantis-bt/.env) :"
echo ">>>        Hostname     : mysql"
echo ">>>        Database     : bugtracker"
echo ">>>        Username/Password : voir MYSQL_USER / MYSQL_PASSWORD dans .env"
echo ">>>   3) Créer le compte administrateur MantisBT via l'assistant"
echo ">>>   4) Une fois l'installation terminée, désactiver l'accès admin :"
echo ">>>        - éditer ~/mantis-bt/docker-compose.yml"
echo ">>>        - remplacer MANTIS_ENABLE_ADMIN: 1 par MANTIS_ENABLE_ADMIN: 0"
echo ">>>        - puis : cd ~/mantis-bt && sudo docker compose up -d"
echo ""
echo ">>> RAPPEL : pour toute commande docker compose ultérieure (logs, ps, down...),"
echo ">>>          se placer d'abord dans le dossier du projet : cd ~/mantis-bt"

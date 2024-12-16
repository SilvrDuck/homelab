set -e
set -x
set -o pipefail

# pre-commit
pipx install pre-commit
pre-commit install

# networking
docker network create web
mkdir -p ./data/traefik/acme
touch ./data/traefik/acme/acme.json
sudo chmod 600 ./data/traefik/acme/acme.json
touch .env

# tailscale
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list
sudo apt-get update
sudo apt-get install tailscale -y
sudo tailscale up

# psa
echo "Your tailscale ip is $(tailscale ip -4)"
echo "Need to chmod 600 ./data/traefik/acme/acme.json"
echo "Need to fill up .env file"

pipx install pre-commit
pre-commit install
docker network create web
mkdir -p ./data/traefik/acme
touch ./data/traefik/acme/acme.json
echo "Need to chmod 600 ./data/traefik/acme/acme.json"


# networking
docker network create web
mkdir -p ./data/traefik/acme
touch ./data/traefik/acme/acme.json
sudo chmod 600 ./data/traefik/acme/acme.json
cp .env.dist .env

set -e
set -x
set -o pipefail

./scripts/setup_docker.sh
./scripts/setup_networking.sh
./scripts/setup_pre_commit.sh
./scripts/setup_tailscale.sh

echo "Need to fill up .env file"

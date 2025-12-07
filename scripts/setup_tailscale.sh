curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list
sudo apt-get update
sudo apt-get install tailscale -y
# Connect to Tailscale, advertise as an exit node, but do not override host DNS.
sudo tailscale up --accept-dns=false --advertise-exit-node
echo "Your tailscale ip is $(tailscale ip -4)"
echo "IMPORTANT: Enable the exit node in the Tailscale admin console."

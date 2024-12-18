# homelab

This is most of the stuff needed for my homelab setup.

If you somehow stumbled onto this repo, keep in mind it is only meant for my specific personnal setup and many things might break for you. Feel free to use anything here as a stepping stone for your own setup :)

The general setup is a proxmox machine with this repo running on an ubuntu 22.04 LXC.

## Quickstart

*Assumes ubuntu 22.04*

- install docker https://docs.docker.com/engine/install/ubuntu/
- Ensure tailscale https://tailscale.com/kb/1130/lxc-unprivileged

Then:

```
sudo ./setup.sh
docker compose up -d
```

## Ressources

A bunch of links that were useful to me while setting this all up.

- https://blog.kye.dev/proxmox-series
- https://trash-guides.info/ (servarr stack best practices and guides)


## Dyndns

Needed manual setting for infomaniak.

On ubiquiti USG:
```
configure
set service dns dynamic interface eth0 service custom host-name 'sub.domain.ch'
set service dns dynamic interface eth0 service custom login 'user'
set service dns dynamic interface eth0 service custom password 'pass'
set service dns dynamic interface eth0 service custom protocol 'https'
set service dns dynamic interface eth0 service custom server 'infomaniak.com'
commit ; save ; exit
update dns dynamic interface eth0
show dns dynamic status
```

Then port forward 80 and 443 to this instance.

Ressources:
- https://help.ui.com/hc/en-us/articles/204976324-EdgeRouter-Custom-Dynamic-DNS
- https://www.infomaniak.com/en/support/faq/2376/dyndns-via-infomaniak-api

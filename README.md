# Docker Container - VPNC Client

## Description

This images builds the latest VPNC from source, all linux distributions don't ship any current versions.

## Deployment Snippet

```yaml
containers:
- name: vpn
  image: envcli/vpnc:latest
  securityContext:
    capabilities:
      add:
      - NET_ADMIN
```

## Examples

### FritzBox

```bash
docker run -it --rm --cap-add=NET_ADMIN --env VPNC_GATEWAY="yourBox.myfritz.net" --env VPNC_ID="userName" --env VPNC_SECRET="sharedSecret" --env VPNC_USERNAME="userName" --env VPNC_PASSWORD="userPassword" envcli/vpnc:latest vpnc --debug 2 --no-detach
```

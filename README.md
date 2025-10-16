# atproto-nix.org NixOS Configuration

NixOS configuration for snek.cc hosting ATProto services.

## Services

- **Bluesky PDS** - Personal Data Server at `pds.snek.cc`
- **Microcosm Constellation** - Available at `constellation.snek.cc` (alias: `con.snek.cc`)
- **Microcosm Spacedust** - Available at `spacedust.snek.cc` (alias: `sd.snek.cc`)
- **Static Sites** - Main site and PDSLS at `snek.cc` and `pdsls.snek.cc`

## Features

- Rate-limited API endpoints (10 req/s, burst 20)
- Automatic TLS with on-demand certificate generation
- Caddy reverse proxy with custom rate limiting plugin
- sops-nix for secrets management

## Secrets Management

Secrets are managed using sops-nix with age encryption via SSH host key:
- `pds_jwt_secret` - JWT signing key for PDS
- `pds_admin_password` - Admin password
- `pds_plc_rotation_key` - PLC rotation key
- `acme_email` - Email for ACME/Let's Encrypt

Edit secrets with:
```bash
sops secrets.sops.yaml
```

## Deployment

```bash
nixos-rebuild switch --flake .#nixos
```

## Repository

[tangled](tangled.sh:atproto-nix.org/nixos)

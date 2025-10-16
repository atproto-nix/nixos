{ config, pkgs, ... }:

let
  jetstreamUrl = "wss://jetstream1.us-west.bsky.network/subscribe";
  domainName = "snek.cc";
  pdsDataDir = "/var/lib/pds";
  bskyAppViewHost = "api.bsky.app";
  bskyReportServiceHost = "mod.bsky.app";
  caddyWebRoot = "/var/www/${domainName}";
  cacheControlLong = "public, max-age=31536000, immutable";

  mkCommonCaddyHeaders = ''
    header {
      X-Frame-Options "SAMEORIGIN"
      X-Content-Type-Options "nosniff"
      X-XSS-Protection "1; mode=block"
      Referrer-Policy "strict-origin-when-cross-origin"
    }
  '';

  # This function generates the Caddy configuration for a rate-limited reverse proxy.
  # It takes one argument: the local address to proxy requests to.
  mkRateLimitedProxy = proxyTarget: ''
    # Use a 'route' block to enforce the order of operations.
    # This ensures @api_limit is defined before rate_limit tries to use it.
    route {
      @api_limit {
        not remote_ip 127.0.0.1
      }
      rate_limit @api_limit {
        rate  10r/s
        burst 20
      }
      reverse_proxy ${proxyTarget}
    }
  '';

in
{
  imports = [
    ./hardware-configuration.nix
  ];

  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
    forceInstall = true;
  };

  networking.getaddrinfo.enable = true;
  networking.getaddrinfo.precedence = {
    "::ffff:0:0/96" = 100;
  };

  time.timeZone = "America/New_York";
  services.timesyncd.enable = true;

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    substituters = [
      "https://cache.nixos.org/"
      "https://nix-community.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dC7NAD3LXGrcQy321AOfz4EJE+SDXvJms="
    ];
  };

  users.users.atproto = {
    isNormalUser = true;
    description = "atproto";
    home = "/home/atproto/";
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBoL3f3N/4bGISiXj+leUETgGxXlEI42+Qq39rZPam1l jvalinsky@users.noreply.github.com"
    ];
  };

  environment.systemPackages = with pkgs; [
    neovim
    git
    wget
    btop
    age
    sops
  ];

  # --- SERVICES ---
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  services.microcosm-constellation = {
    enable = true;
    jetstream = jetstreamUrl;
  };

  services.microcosm-spacedust = {
    enable = true;
    jetstream = jetstreamUrl;
  };

  services.bluesky-pds = {
    enable = true;
    settings = {
      PDS_HOSTNAME = "pds.${domainName}";
      PDS_DATA_DIRECTORY = pdsDataDir;
      PDS_BLOBSTORE_DISK_LOCATION = "${pdsDataDir}/blocks";
      PDS_BLOB_UPLOAD_LIMIT = "52428800";
      PDS_DID_PLC_URL = "https://plc.directory";
      PDS_BSKY_APP_VIEW_URL = "https://${bskyAppViewHost}";
      PDS_BSKY_APP_VIEW_DID = "did:web:${bskyAppViewHost}";
      PDS_REPORT_SERVICE_URL = "https://${bskyReportServiceHost}";
      PDS_REPORT_SERVICE_DID = "did:plc:ar7c4by46qjdydhdevvrndac";
      PDS_CRAWLERS = "https://bsky.network";
      LOG_ENABLED = "true";
    };
    environmentFiles = [ config.sops.templates.pds_env.path ];
  };

  # --- CADDY REVERSE PROXY ---
  services.caddy = {
    enable = true;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/mholt/caddy-ratelimit@v0.1.0" ];
      hash = "sha256-jw7LZP4P+9QHXYJ0R6SxphDDvwNNr6F3FGuzlaHiFbc=";
    };

    globalConfig = ''
      email ${config.sops.placeholder.acme_email}
      on_demand_tls {
        ask http://127.0.0.1:3000/tls-check
      }
    '';
    logFormat = ''
      output file /var/log/caddy/access.log
    '';
    virtualHosts = {
      "*.pds.${domainName}, pds.${domainName}" = {
        extraConfig = ''
          tls {
            on_demand
          }
          reverse_proxy http://127.0.0.1:3000
        '';
      };
      "constellation.${domainName}, con.${domainName}" = {
        extraConfig = mkRateLimitedProxy "http://127.0.0.1:6789";
      };
      "spacedust.${domainName}, sd.${domainName}" = {
        extraConfig = mkRateLimitedProxy "http://127.0.0.1:8765";
      };
      "${domainName}" = {
        extraConfig = ''
          root * ${caddyWebRoot}
          file_server
          ${mkCommonCaddyHeaders}
                    @fonts path /fonts/*
                    header @fonts Cache-Control "${cacheControlLong}"
        '';
      };
      "pdsls.${domainName}" = {
        extraConfig = ''
          root * ${caddyWebRoot}/pdsls
          file_server
          ${mkCommonCaddyHeaders}
          @assets path /assets/*
          header @assets Cache-Control "${cacheControlLong}"
          @headers path /headers/*
          header @headers Cache-Control "public, max-age=86400"
        '';
      };
    };
  };

  # --- SOPS-NIX CONFIGURATION ---
  sops = {
    defaultSopsFile = ./secrets.sops.yaml;
    # age.keyFile = "/root/.config/sops/age/keys.txt";
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets = {
      pds_jwt_secret = { };
      pds_admin_password = { };
      pds_plc_rotation_key = { };
      acme_email = { };
    };
    templates."pds_env" = {
      content = ''
        PDS_JWT_SECRET=${config.sops.placeholder.pds_jwt_secret}
        PDS_ADMIN_PASSWORD=${config.sops.placeholder.pds_admin_password}
        PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=${config.sops.placeholder.pds_plc_rotation_key}
      '';
      mode = "0400";
      owner = "pds";
      group = "pds";
    };
  };

  systemd.services.bluesky-pds.after = [ "sops-secrets.service" ];

  networking.firewall.allowedTCPPorts = [
    22
    80
    443
    3000
    6789
    8765
  ];

  system.stateVersion = "25.05";

  systemd.tmpfiles.rules = [
    "d ${pdsDataDir} 0755 pds pds -"
    "d ${pdsDataDir}/blocks 0755 pds pds -"
  ];
}

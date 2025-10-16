{
  description = "NixOS configuration for nixos server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";

    nur = {
      url = "github:atproto-nix/nur";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      sops-nix,
      nur,
      ...
    }:
    let
      system = "x86_64-linux";
    in
    {
      nixosConfigurations = {
        # Hostname for your new system
        nixos = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            sops-nix.nixosModules.sops
            {
              nixpkgs.config.allowUnfree = true;
              nixpkgs.overlays = [
                (final: prev: { nur = nur.packages.${prev.system}; })
              ];
            }
            # The main system configuration
            ./configuration.nix

            # The NixOS module from your NUR that provides the constellation service
            nur.nixosModules.${system}.microcosm
          ];
        };
      };
    };
}

{
  description = "Install ArchLinux ARM in Raspberry Pi 5";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      basePkgs = pkgs: with pkgs; [
        aria2
        dosfstools
        e2fsprogs
        libarchive
        fzf
        gawk
        findutils
        curl
        gnugrep
        coreutils
        util-linux
        parted
      ];

      forAllSystems = f: builtins.listToAttrs (map (system: {
        name = system;
        value = f system nixpkgs.legacyPackages.${system};
      }) systems);
    in
    {
      packages = forAllSystems (_system: pkgs: {
        default = pkgs.writeShellApplication {
          name = "alarm-install";
          runtimeInputs = basePkgs pkgs;
          text = builtins.readFile ./build.sh;
        };
      });

      devShells = forAllSystems (system: pkgs: {
        default = pkgs.mkShell {
          name = "alarm-install-devshell";
          meta.description = "Shell environment for alarm_install script";
          packages = basePkgs pkgs ++ [ self.packages.${system}.default ];
        };
      });
    };
}

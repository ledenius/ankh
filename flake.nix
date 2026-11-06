{
  description = "ankh: identity bootstrap for a fresh machine (a gpg key, a pass store, SSH)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # ankh is one bash script with no build step. Its required tools are
      # put on PATH by the wrapper; optional ones (paperkey, qrencode) too,
      # so `nix run` has everything. pinentry is gpg-agent's to choose.
      mkAnkh = pkgs: pkgs.stdenv.mkDerivation {
        pname = "ankh";
        version = "0.1.0-dev";
        src = self;
        nativeBuildInputs = [ pkgs.makeWrapper ];
        dontBuild = true;
        installPhase = ''
          runHook preInstall

          install -Dm755 ankh "$out/bin/ankh"
          install -Dm755 ankh-verify "$out/bin/ankh-verify"
          install -Dm644 comp/bash/ankh "$out/share/bash-completion/completions/ankh"
          install -Dm644 comp/zsh/_ankh "$out/share/zsh/site-functions/_ankh"
          install -Dm644 comp/fish/ankh.fish "$out/share/fish/vendor_completions.d/ankh.fish"

          runHook postInstall
        '';
        postFixup = ''
          wrapProgram "$out/bin/ankh" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.bash pkgs.gnupg pkgs.pass pkgs.git pkgs.openssh pkgs.rsync pkgs.paperkey pkgs.qrencode pkgs.curl ]}
        '';
        meta = with pkgs.lib; {
          description = "Identity bootstrap for a fresh machine";
          homepage = "https://codeberg.org/lede/ankh";
          license = licenses.gpl3Plus;
          mainProgram = "ankh";
          platforms = platforms.unix;
        };
      };
    in
    {
      homeManagerModules.default = { pkgs, ... }: {
        home.packages = [ (mkAnkh pkgs) ];
      };
    }
    // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages.default = mkAnkh pkgs;
        apps.default = flake-utils.lib.mkApp { drv = mkAnkh pkgs; };
      }
    );
}

{
  description = "NixOS module for MicroClaw: multi-instance agent runtime that can pin upstream governance files (AGENTS.md scopes, SOUL.md) as kernel-enforced read-only store mounts, seeds agent-owned soul layers and skills no-clobber, and injects secrets by file path (secret-manager-agnostic)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      nixosModules.microclaw = ./modules/microclaw.nix;
      nixosModules.default = self.nixosModules.microclaw;

      lib = forAllSystems (pkgs: {
        # Render a MicroClaw config attrset to a secret-free YAML store
        # path; the module's preStart reseeds the mutable copy from it and
        # injects secrets from FILES at runtime (see README).
        renderConfig = name: attrs: (pkgs.formats.yaml { }).generate name attrs;
      });

      templates.default = {
        path = ./examples;
        description = "Example host configuration consuming the microclaw module";
      };

      checks = forAllSystems (pkgs: {
        # `nix flake check` evaluates modules/microclaw.nix merged with
        # test/eval-example.nix; the eval assertions there do the real
        # checking and the grep below double-belts the critical strings.
        eval =
          let
            evaluated = nixpkgs.lib.evalModules {
              modules = [
                ./modules/microclaw.nix
                ./test/eval-example.nix
              ];
              specialArgs = { inherit pkgs; };
            };
            svc = evaluated.config.systemd.services.microclaw-alice;
            # Enforce the eval-example assertions (plain evalModules merges
            # them into an option but does not always raise), so a broken
            # invariant is a hard failure rather than inert data.
            assertAll = builtins.foldl'
              (acc: a: if a then acc else throw "microclaw eval assertion failed")
              true
              (map (a: a.assertion) (evaluated.config.assertions or [ ]));
            evidence = pkgs.writeText "microclaw-eval-evidence" (builtins.seq assertAll ''
              preStart:
              ${svc.preStart}
              binds: ${builtins.toJSON (svc.serviceConfig.BindReadOnlyPaths or [ ])}
              tmpfiles: ${builtins.toJSON evaluated.config.systemd.tmpfiles.rules}
            '');
          in
          pkgs.runCommand "microclaw-nix-eval-check" { } ''
            grep -q "cp -f" "${evidence}"
            grep -q "strenv(SECRET)" "${evidence}"
            grep -q "cp -rn" "${evidence}"
            grep -q "global-AGENTS.md" "${evidence}"
            grep -q '^C /var/lib/microclaw-alice' "${evidence}" || grep -q "C /var/lib/microclaw-alice/groups/telegram/SOUL.md" "${evidence}"
            # every Nix-owned governance file must be a kernel RO bind
            grep -q "binds: .*groups/telegram/AGENTS.md" "${evidence}"
            grep -q "tmpfiles: .*d /var/lib/microclaw-alice/groups/telegram 0755" "${evidence}"
            echo ok > "$out"
          '';
      });
    };
}

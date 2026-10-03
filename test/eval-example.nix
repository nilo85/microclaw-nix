/*
  Eval test consumed by `nix flake check`: instantiates one `alice`
  instance against stubbed NixOS option namespaces and asserts the
  security-critical invariants of the generated unit. Evaluation itself
  fails the check if any assertion below does not hold.
*/
{ config, lib, pkgs, ... }:
let
  m = config.microclaw;
  svc = config.systemd.services.microclaw-alice;
  constitutionFile = ./fixtures/constitution.md;
  secretFile = ./fixtures/token.txt;
in
{
  # Stubs for the NixOS option namespaces the module writes to (plain
  # evalModules does not load the real systemd/tmpfiles/etc modules, and
  # does not even define assertions/warnings - those come from
  # nixos eval-config).
  options = {
    assertions = lib.mkOption { type = lib.types.listOf lib.types.raw; default = [ ]; };
    warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    systemd.services = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
    systemd.tmpfiles.rules = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    environment.etc = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
    networking.firewall.allowedTCPPorts = lib.mkOption { type = lib.types.listOf lib.types.int; default = [ ]; };
    users.users = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
    users.groups = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
  };

  config.microclaw = {
    package = pkgs.hello; # any derivation; we only check string shapes
    instances.alice = {
      dataDir = "/var/lib/microclaw-alice";
      constitution = constitutionFile;
      secrets = [ {
        key = ".channels.telegram.accounts.alice.bot_token";
        file = secretFile;
      } ];
      webPasswordFile = ./fixtures/password.txt;
      seedDirs = [ {
        src = ./fixtures/souls;
        dst = "souls";
      } ];
      stateFiles = {
        "groups/telegram/AGENTS.md" = toString ./fixtures/household.md;
      };
      disabledSkills = [ "xlsx" "pptx" ];
      serviceAfter = [ "llama-swap.service" ];
      openFirewall = true;
      config = {
        llm = {
          default_provider = "litellm";
          providers.litellm = {
            base_url = "http://127.0.0.1:4000/v1";
            model = "agent-small";
          };
        };
        channels.telegram = {
          enabled = true;
          allowed_user_ids = [ 123 ];
          accounts.alice = { };
        };
        web = {
          enabled = true;
          port = 10999;
        };
      };
    };
  };

  config.assertions = [
    {
      assertion = m.instances ? alice;
      message = "instance not merged";
    }
    {
      assertion = svc.serviceConfig.BindReadOnlyPaths == [
        "${toString constitutionFile}:/var/lib/microclaw-alice/groups/AGENTS.md"
      ];
      message = "constitution bind missing or wrong: ${toString (svc.serviceConfig.BindReadOnlyPaths or [ ])}";
    }
    {
      assertion = lib.any (l: lib.hasPrefix "C /var/lib/microclaw-alice/groups/telegram/AGENTS.md" l) config.systemd.tmpfiles.rules;
      message = "tmpfiles C seed rule missing";
    }
    {
      assertion =
        lib.strings.hasInfix "cp -f" svc.preStart
        && lib.strings.hasInfix "strenv(SECRET)" svc.preStart
        && lib.strings.hasInfix "cp -rn" svc.preStart
        && lib.strings.hasInfix ".[\"xlsx\"] = false" svc.preStart
        && lib.strings.hasInfix "refusing to start" svc.preStart;
      message = "preStart lost one of: config reseed / secret inject / no-clobber seed / skill gate / fail-fast";
    }
    {
      assertion = svc.restartTriggers or [ ] != [ ];
      message = "restartTriggers empty: config changes would not restart the unit";
    }
    {
      assertion = config.networking.firewall.allowedTCPPorts == [ 10999 ];
      message = "firewall port not opened from config.web.port";
    }
    {
      assertion = lib.strings.hasInfix "ProtectSystem" (builtins.toJSON svc.serviceConfig);
      message = "hardening flags missing";
    }
    {
      assertion = config.environment.etc."microclaw/alice/microclaw.config.yaml".source != null;
      message = "etc render missing";
    }
  ];
}

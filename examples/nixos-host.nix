/*
  Example: consuming microclaw-nix from a host flake. Deliberately
  host-agnostic - everything specific to a deployment (package source,
  secret files, personas) is passed in.
*/
{
  config,
  pkgs,
  ...
}:
let
  # A tiny secret-free config for one assistant instance.
  baseConfig = {
    llm = {
      default_provider = "litellm";
      providers.litellm = {
        base_url = "http://127.0.0.1:4000/v1";
        model = "agent-small";
        model_context_window = 65536;
      };
    };
    channels.telegram = {
      enabled = true;
      allow_bots = "none";
      allowed_user_ids = [ 111111 ]; # host-specific: your user ids
      accounts.assistant = {
        soul_path = "/var/lib/microclaw-assistant/souls/assistant/base.md";
        default = true;
        allow_chats = [ 111111 ];
      };
    };
    web = {
      enabled = true;
      port = 10962;
    };
    server.heartbeat = {
      enabled = false;
      agent_id = "assistant";
    };
  };
in
{
  imports = [ microclaw-nix.nixosModules.microclaw ];

  microclaw = {
    # The module does NOT pin MicroClaw itself - provide it however you
    # like (nixpkgs, your own overlay, a flake input):
    package = pkgs.microclaw;

    instances.assistant = {
      dataDir = "/var/lib/microclaw-assistant";
      config = baseConfig;

      # Plane 1: governance, kernel-read-only, always the Nix version.
      constitution = ./constitution.md;

      # Plane 2: volatile personas/skills, seeded no-clobber, never
      # overwritten by Nix once present.
      seedDirs = [
        {
          src = ./souls;
          dst = "souls";
        }
        {
          src = ./skills;
          dst = "skills";
        }
      ];

      # Plane 3: shared state skeletons, copy-IF-absent forever after.
      stateFiles."groups/telegram/AGENTS.md" = ./shared/household-skeleton.md;

      # Secrets as FILES - works with any secret manager that drops 0400
      # files readable by the service user. sops-nix example:
      #   sops.secrets."telegram/assistant-token" = {
      #     group = config.microclaw.group; mode = "0440";
      #   };
      secrets = [
        {
          key = ".channels.telegram.accounts.assistant.bot_token";
          file = "/run/secrets/telegram-assistant-token";
        }
        {
          key = ".channels.telegram.accounts.assistant.bot_username";
          file = "/run/secrets/telegram-assistant-botname";
        }
      ];
      webPasswordFile = "/run/secrets/microclaw-web-password";

      # Per-instance skill gating (declarative default, merged into
      # runtime/skills_state.json so agent-side edits survive):
      disabledSkills = [ "xlsx" "pptx" ];

      serviceAfter = [ "litellm.service" ];
      serviceWants = [ "litellm.service" ];
    };
  };

  # Example of two isolated bots: add a second entry to `instances` with its
  # own dataDir/config/secrets; each becomes its own microclaw-<name> unit.
}

/*
  Example: consuming microclaw-nix from a host flake. The config attrset is
  passed through to YAML verbatim, so it uses MicroClaw's real (flat) keys.
  Everything deployment-specific (package source, secret files, personas,
  user ids) is supplied by the host - nothing here is baked into the module.
*/
{
  config,
  pkgs,
  ...
}:
let
  baseConfig = {
    llm_provider = "openai";
    llm_base_url = "http://127.0.0.1:4000/v1";
    model = "agent-small";
    api_key = "sk-local-no-auth"; # required even for local backends
    llm_providers.openai.models = [ "agent-small" ];
    model_context_window = 65536;
    show_thinking = false;
    max_tokens = 2048;
    system_prompt_time_detail = "date";
    control_chat_ids = [ 111111 ];

    web_enabled = true;
    web_host = "0.0.0.0";
    web_port = 10962;

    tool_policy = {
      mode = "block";
      max_risk = "medium";
      deny_tools = [ "sync_skills" ];
    };
    heartbeat = {
      enabled = false;
      interval_mins = 45;
    };

    channels.telegram = {
      enabled = true;
      allow_groups = true;
      allowed_user_ids = [ 111111 ];
      default_account = "assistant";
      accounts.assistant = {
        soul_path = "souls/assistant.md"; # relative to dataDir
        bot_token = ""; # injected by preStart
        bot_username = ""; # injected by preStart
      };
    };
  };
in
{
  imports = [ microclaw-nix.nixosModules.microclaw ];

  microclaw = {
    package = pkgs.microclaw; # provide via nixpkgs/overlay/another flake

    instances.assistant = {
      dataDir = "/var/lib/microclaw-assistant";
      config = baseConfig;

      constitution = ./constitution.md;
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
      stateFiles."groups/telegram/AGENTS.md" = ./shared/household-skeleton.md;

      # Let the secret manager tell you where the decrypted file actually
      # lives - never hardcode its runtime layout. (sops-nix shown; any
      # secret manager that exposes a path option works the same way.)
      secrets = [
        {
          key = ".channels.telegram.accounts.assistant.bot_token";
          file = config.sops.secrets.microclaw-assistant-token.path;
        }
        {
          key = ".channels.telegram.accounts.assistant.bot_username";
          file = config.sops.secrets.microclaw-assistant-botname.path;
        }
      ];
      webPasswordFile = config.sops.secrets.microclaw-web-password.path;

      disabledSkills = [ "xlsx" "pptx" ];
      firewallTCPPorts = [ 10962 ];
      serviceAfter = [ "litellm.service" ];
      extraPath = [ pkgs.git pkgs.curl ];
    };
  };

  # A second bot = a second `instances.<name>` entry with its own dataDir,
  # config, secrets and microclaw-<name> unit. Filesystem isolation, shared
  # package/user.
}

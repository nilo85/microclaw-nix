/*
  microclaw-nix: reusable NixOS module for MicroClaw agent instances with a
  hardened three-plane state model:

    plane 1  constitution  <dataDir>/groups/AGENTS.md  kernel-read-only
             (BindReadOnlyPaths from the store path), so content is by
             definition always the Nix version; the agent cannot rewrite its
             own governance (see microclaw/microclaw#501).
    plane 2  personality   souls/, skills/, per-chat SOUL.md: seeded
             no-clobber, agent-owned, NEVER overwritten by Nix afterwards.
    plane 3  state         bot/chat memory + seeded skeletons (tmpfiles C,
             copy-if-absent), mutable by the agent.

  The mutable config is reseeded from the Nix render on EVERY start, then
  secrets are injected from FILES (`secrets = [ { key = "<yq path>"; file =
  <path>; } ]`), keeping this module agnostic about the secret manager
  (sops-nix, agenix, systemd-credentials, ...).

  No host-specific information: the MicroClaw package, personas, skills and
  secret paths all arrive as parameters.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.microclaw;
  yqBin = lib.getExe pkgs.yq-go;

  secretSubmodule = lib.types.submodule (
    { ... }:
    {
      options = {
        key = lib.mkOption {
          type = lib.types.str;
          example = ".channels.telegram.accounts.alice.bot_token";
          description = "yq path expression where the secret value is written in the mutable config.";
        };
        file = lib.mkOption {
          type = lib.types.path;
          example = lib.literalExpression "\"/run/secrets/alice-token\"";
          description = "File holding the secret value, readable by the service user at runtime (e.g. a sops/age-deployed 0400 file). Must be NON-EMPTY or the unit fails fast.";
        };
      };
    }
  );

  seedSubmodule = lib.types.submodule (_: {
    options = {
      src = lib.mkOption {
        type = lib.types.path;
        description = "Store directory to seed from.";
      };
      dst = lib.mkOption {
        type = lib.types.str;
        example = "souls";
        description = "Target path relative to the instance dataDir.";
      };
    };
  });

  instanceSubmodule = lib.types.submodule (
    { name, ... }:
    {
      options = {
        dataDir = lib.mkOption {
          type = lib.types.str;
          example = "/var/lib/microclaw-alice";
          description = "Absolute data directory under /var/lib (StateDirectory is its basename there).";
        };

        workingDir = lib.mkOption {
          type = lib.types.str;
          default = "/srv/microclaw-${name}";
          description = "Service WorkingDirectory (seeded via tmpfiles).";
        };

        config = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          description = "Secret-free MicroClaw config attrset, rendered to the store and reseeded over the mutable copy every start. data_dir/working_dir are injected automatically if absent.";
        };

        secrets = lib.mkOption {
          type = lib.types.listOf secretSubmodule;
          default = [ ];
          description = "Per-start secret injections into the mutable config, values read from FILES.";
        };

        webPasswordFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Optional single-line file re-applying the Web UI password every start (it lives only as a hash in the state db, so rotation takes effect on restart). Missing/empty file => warn and keep current.";
        };

        constitution = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = lib.literalExpression "./constitution.md";
          description = "Store file bind-mounted READ-ONLY onto <dataDir>/groups/AGENTS.md: writes fail EROFS, unlink fails EBUSY, and the source being a store path keeps the live constitution always identical to the Nix version. Must be NON-EMPTY.";
        };

        seedDirs = lib.mkOption {
          type = lib.types.listOf seedSubmodule;
          default = [ ];
          example = [ { src = ./souls; dst = "souls"; } ];
          description = "Directories copied with `cp -rn` (no-clobber) every start; existing files are never overwritten - volatile agent data. Copies are chmod'd writable so agent self-learning keeps working (store modes are read-only).";
        };

        stateFiles = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          example = { "groups/telegram/AGENTS.md" = lib.literalExpression "./household-skeleton.md"; };
          description = "Files seeded ONCE into mutable paths via tmpfiles `C` (copy-if-absent; `c` is char-dev, `f` writes the literal argument). Key = path relative to dataDir, value = source path.";
        };

        disabledSkills = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Skill names disabled for THIS instance, merged into runtime/skills_state.json every start (`<name> = false`). Merged, never replaced, so agent-side state keeps self-governing; built-in skills cannot be deleted, so this is the supported gating path.";
        };

        serviceAfter = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Extra After= (e.g. an LLM proxy unit).";
        };
        serviceBindsTo = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        serviceWants = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        extraPath = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "Extra tools on the unit PATH (git, curl, sqlite, ...).";
        };
        env = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
        };
        openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open config.web.port in the host firewall (web UI binds localhost-only by default; only meaningful if you expose it).";
        };
      };
    }
  );

  mkInstance =
    name: ic:
    let
      unit = "microclaw-${name}";
      pkg = cfg.package;
      microclawExe = "${pkg}/bin/${cfg.binaryName}";
      mutableConfigPath = "${ic.dataDir}/microclaw.config.yaml";
      staticConfig = (pkgs.formats.yaml { }).generate "${name}-microclaw.config.yaml" (
        {
          data_dir = ic.dataDir;
          working_dir = ic.workingDir;
        }
        // ic.config
      );
      constitutionTarget = "${ic.dataDir}/groups/AGENTS.md";
      secretEmptyCheck = lib.concatMapStringsSep "\n" (
        s: ''
          if [ ! -s ${lib.escapeShellArg (toString s.file)} ]; then
            echo "${unit}: ${toString s.file} missing or empty; refusing to start" >&2
            exit 1
          fi
        ''
      ) ic.secrets;
      secretInjects = lib.concatMapStringsSep "\n" (
        s: ''
          SECRET=$(/bin/cat ${lib.escapeShellArg (toString s.file)}) \
          ${yqBin} -i '(${s.key}) = strenv(SECRET)' ${lib.escapeShellArg mutableConfigPath}
        ''
      ) ic.secrets;
      seedDirCmds = lib.concatMapStringsSep "\n" (
        d: ''
          if [ -d ${lib.escapeShellArg (toString d.src)} ]; then
            mkdir -p ${lib.escapeShellArg d.dst}
            cp -rn ${lib.escapeShellArg (toString d.src)}/. ${lib.escapeShellArg d.dst}/ 2>/dev/null || true
            # Store modes are read-only; make the copy writable so governed
            # learning (agent self-editing personas/skills) keeps working.
            chmod -R u+rwX ${lib.escapeShellArg d.dst}
            echo "${unit}: seeded ${lib.escapeShellArg d.dst} (existing files kept)"
          fi
        ''
      ) ic.seedDirs;
      skillGateCmds = lib.concatMapStringsSep "\n" (
        n: "${yqBin} -i '.[\"${n}\"] = false' \"$skills_state\""
      ) ic.disabledSkills;
    in
    {
      assertions = [
        {
          assertion = lib.hasPrefix "/var/lib/" ic.dataDir;
          message = "microclaw-${name}: dataDir must live under /var/lib (StateDirectory maps it); got ${ic.dataDir}";
        }
        {
          assertion = ic.config != { };
          message = "microclaw-${name}: config attrset is empty";
        }
      ];

      warnings = lib.optionals (ic.openFirewall && !(ic.config ? web)) [
        "microclaw-${name}: openFirewall is true but config has no `web` attribute; nothing to open."
      ];

      systemd.services.${unit} = {
        description = "MicroClaw agent runtime (${name})";
        documentation = [ "https://github.com/microclaw/microclaw" ];
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ] ++ ic.serviceWants;
        after = [ "network-online.target" ] ++ ic.serviceAfter;
        bindsTo = ic.serviceBindsTo;

        environment = {
          MICROCLAW_CONFIG = mutableConfigPath;
          HOME = ic.dataDir;
          RUST_LOG = "info";
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        } // ic.env;

        # The mutable config is NIX-OWNED: always reseed from the rendered
        # store file, then inject secrets from files. (Seed-only-when-absent
        # previously let stale config - including tool policy - survive
        # rebuilds for days.)
        preStart = ''
          cfg_file=${lib.escapeShellArg mutableConfigPath}
          echo "${unit}: seeding $cfg_file from the Nix-rendered config"
          cp -f ${lib.escapeShellArg (toString staticConfig)} "$cfg_file"
          chmod 0600 "$cfg_file"

          # Fail BEFORE writing anything: empty secret = broken forever.
          ${secretEmptyCheck}
          ${lib.optionalString (ic.constitution != null) ''
            if [ ! -s ${lib.escapeShellArg (toString ic.constitution)} ]; then
              echo "${unit}: constitution file is empty; governance plane must not be blank" >&2
              exit 1
            fi
          ''}
          ${secretInjects}

          ${lib.optionalString (ic.webPasswordFile != null) ''
            pw_file=${lib.escapeShellArg (toString ic.webPasswordFile)}
            if [ ! -s "$pw_file" ]; then
              echo "${unit}: $pw_file missing or empty, keeping the current Web UI password" >&2
            else
              ${lib.escapeShellArg microclawExe} --config "$cfg_file" web password "$(/bin/cat "$pw_file")"
            fi
          ''}

          # Plane 2 seeds: personas + skills, NEVER clobbering - agent-owned
          # volatile data must survive restarts.
          ${seedDirCmds}

          # Declarative per-instance skill gating (plane-3-adjacent: merged,
          # not replaced, so agent-managed entries keep self-governing).
          skills_state=${lib.escapeShellArg "${ic.dataDir}/runtime/skills_state.json"}
          mkdir -p "$(dirname "$skills_state")"
          if [ ! -e "$skills_state" ]; then
            printf '{}' > "$skills_state"
          fi
          ${skillGateCmds}
        '';

        serviceConfig = {
          ExecStart = lib.escapeShellArgs [
            microclawExe
            "start"
          ];
          WorkingDirectory = ic.workingDir;
          # Relative to /var/lib; systemd rejects absolute values.
          StateDirectory = lib.removePrefix "/var/lib/" ic.dataDir;
          Restart = "on-failure";
          RestartSec = "5";
          TimeoutStopSec = "30";
          StartLimitIntervalSec = 300;
          StartLimitBurst = 5;

          # An agent with file tools on a box with GPUs deserves a jail.
          ProtectSystem = "full";
          ProtectKernelTunables = true;
          ProtectControlGroups = true;
          RestrictSUIDSGID = true;
          NoNewPrivileges = true;
          ProtectHome = true;
          PrivateTmp = true;
        }
        // lib.optionalAttrs cfg.createAccounts {
          User = cfg.user;
          Group = cfg.group;
        }
        // lib.optionalAttrs (!cfg.createAccounts) {
          DynamicUser = true;
        }
        // lib.optionalAttrs (ic.constitution != null) {
          # Plane 1, kernel-enforced: read-only inside the unit namespace,
          # unlink => EBUSY. The mount source IS the store path, so the live
          # constitution is always exactly the Nix version. Note: the bind
          # target exists only inside the unit namespace - on the host,
          # dataDir/groups/AGENTS.md is absent; read it with
          #   nsenter -t $(systemctl show -p MainPID --value ${unit}) -m \
          #     cat ${constitutionTarget}
          BindReadOnlyPaths = [ "${toString ic.constitution}:${constitutionTarget}" ];
        };

        # A store-content change alone would not restart the unit (the config
        # is a symlink), so trigger explicitly.
        restartTriggers =
          [ staticConfig ]
          ++ lib.optionals (ic.constitution != null) [ ic.constitution ];

        path = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnused
          pkgs.yq-go
          pkgs.jq
          pkgs.cacert
        ] ++ ic.extraPath;
      };

      systemd.tmpfiles.rules =
        [
          "d ${ic.workingDir} 0755 ${cfg.user} ${cfg.group} -"
          "d ${ic.dataDir} 0755 ${cfg.user} ${cfg.group} -"
          "d ${ic.dataDir}/groups 0755 ${cfg.user} ${cfg.group} -"
        ]
        ++ lib.mapAttrsToList (
          dst: src: "C ${ic.dataDir}/${dst} 0644 ${cfg.user} ${cfg.group} - ${src}"
        ) ic.stateFiles;

      networking.firewall.allowedTCPPorts =
        let
          webPort = (ic.config.web or { }).port or null;
        in
        lib.optionals (ic.openFirewall && webPort != null) [ webPort ];

      # Debug/convenience: secret-free render visible on the host.
      environment.etc."microclaw/${name}/microclaw.config.yaml".source = staticConfig;
    };
  # IMPORTANT: never assign the whole module `config' to an expression that
  # forces the instances option; the module system would evaluate it while
  # enumerating this module's OWN output (cycle). Aggregating lazily
  # per-option (definitions below) defers instance resolution to option
  # query time.
  perInstance = lib.mapAttrsToList (n: ic: mkInstance n ic) cfg.instances;

in
{
  options.microclaw = {
    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      example = lib.literalExpression "pkgs.microclaw";
      description = "MicroClaw derivation. Provided by the consumer (nixpkgs, an overlay, or a flake input) - this module does not pin or build MicroClaw itself.";
    };

    binaryName = lib.mkOption {
      type = lib.types.str;
      default = "microclaw";
      description = "Executable name inside the package.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "microclaw";
      description = "Service user shared by all instances.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = cfg.user;
      description = "Service group shared by all instances.";
    };

    createAccounts = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Create the static service account; false runs each unit with DynamicUser.";
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf instanceSubmodule;
      default = { };
      description = "One systemd unit microclaw-<name> per entry; isolation between instances is the filesystem (separate dataDirs).";
    };
  };

  config = lib.mkMerge [
    {
      assertions = lib.concatMap (c: c.assertions) perInstance;
      warnings = lib.concatMap (c: c.warnings) perInstance;
      systemd.services = lib.mkMerge (map (c: c.systemd.services) perInstance);
      systemd.tmpfiles.rules = lib.concatMap (c: c.systemd.tmpfiles.rules) perInstance;
      networking.firewall.allowedTCPPorts = lib.concatMap (c: c.networking.firewall.allowedTCPPorts) perInstance;
      environment.etc = lib.mkMerge (map (c: c.environment.etc) perInstance);
    }
    (lib.mkIf (cfg.instances != { }) {
      assertions = [
        {
          assertion = cfg.package != null;
          message = "microclaw: with instances set, microclaw.package must be set (this module does not depend on a specific nixpkgs fork).";
        }
      ];
      users.users = lib.mkIf cfg.createAccounts {
        ${cfg.user} = {
          isSystemUser = true;
          group = cfg.group;
          home = "/var/lib";
        };
      };
      users.groups = lib.mkIf cfg.createAccounts {
        ${cfg.group} = { };
      };
    })
  ];
}

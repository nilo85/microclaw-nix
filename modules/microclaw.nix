/*
  microclaw-nix: reusable NixOS module for MicroClaw agent instances.

  Terminology follows upstream MicroClaw, so a host config reads in the same
  vocabulary as the engine's own docs. Upstream keeps a memory hierarchy under
  <dataDir>/groups/, where one file name (AGENTS.md) serves several scopes, and
  calls AGENTS.md / SOUL.md / USER.md the "governance files" that must not be
  rewritten by the generic file tools (microclaw/microclaw#501):

    global     groups/AGENTS.md                MemoryManager::global_memory_path
    bot        groups/<channel>/AGENTS.md      MemoryManager::bot_memory_path
    chat       groups/<channel>/<id>/AGENTS.md MemoryManager::chat_memory_path
    user model groups/<channel>/<id>/USER.md   MemoryManager::chat_user_model_path
    soul       <soul_path>, default SOUL.md in the data dir  (config.soul_path)
    soul layers <souls_dir>/<name>/*.md        (config.souls_dir)

  This module adds one property on top: Nix can own a governance file outright
  by bind-mounting the store path read-only, so the live file is always exactly
  the Nix version even when the agent has an unsandboxed `bash` (which #501 does
  not cover - it guards write_file / edit_file only).

    globalAgents  store path bind-mounted RO onto <dataDir>/groups/AGENTS.md
    readOnlyFiles other Nix-owned governance files, RO, same mechanism
    seedDirs      soul layers and skills, copied no-clobber, then agent-owned
    stateFiles    mutable scaffolding, seeded copy-if-absent, then agent-owned

  What is deliberately NOT locked down: files that describe the human. A bot
  should be able to record what it learns about a user from conversation, so
  seedDirs covers the per-user layer and the per-chat SOUL.md / USER.md stay
  writable. Only operator-owned governance is pinned to Nix.

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

        globalAgents = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = lib.literalExpression "./global-AGENTS.md";
          description = ''
            Store file bind-mounted read-only onto `<dataDir>/groups/AGENTS.md`,
            upstream's global memory scope (MemoryManager::global_memory_path).

            Writes fail EROFS and unlink fails EBUSY, and because the mount
            source is a store path the live file is always exactly the Nix
            version - including against an unsandboxed `bash`, which
            microclaw#501 does not guard (it covers write_file / edit_file
            only). Must be non-empty.

            Prefer this over listing `groups/AGENTS.md` in `readOnlyFiles`: it
            is the same mount, named after the upstream scope.
          '';
        };

        readOnlyFiles = lib.mkOption {
          type = lib.types.attrsOf (lib.types.oneOf [ lib.types.path lib.types.str ]);
          default = { };
          example = lib.literalExpression ''{
            "groups/telegram/AGENTS.md" = ./groups/telegram/AGENTS.md;  # bot scope
          }'';
          description = ''
            Governance files bind-mounted read-only from the store, keyed by a
            path relative to dataDir. Use it for the scopes `globalAgents`
            does not cover - typically the bot scope
            (`groups/<channel>/AGENTS.md`) in a multi-user deployment, where
            one user's conversation must not be able to edit shared
            governance.

            Same enforcement as `globalAgents`: writes fail EROFS, unlink
            fails EBUSY, and the live file is always exactly the Nix version
            even against an unsandboxed `bash` (microclaw#501 guards only
            write_file / edit_file). Targets exist only inside the unit
            namespace; read one with
              nsenter -t $(systemctl show -p MainPID --value <unit>) -m cat <target>

            Do NOT use this for files describing a human. A bot should be able
            to record what it learns about a user, so `seedDirs` (soul layers)
            and `stateFiles` (per-chat USER.md scaffolding) stay writable.
            Declaring the same relative path in both `readOnlyFiles` and
            `stateFiles` is an error.
          '';
        };

        seedDirs = lib.mkOption {
          type = lib.types.listOf seedSubmodule;
          default = [ ];
          example = [
            {
              src = ./souls;
              dst = "souls";
            } # config.souls_dir
          ];
          description = ''
            Directories copied with `cp -rn` (no-clobber) every start; existing
            files are never overwritten, so this is seeding, not management.
            Copies are chmod'd writable because the store modes are read-only -
            these are the agent's own files afterwards.

            Use it for `souls_dir` layers (the base persona and per-user
            layers) and for `skills/`. The per-user layer belongs here rather
            than in `readOnlyFiles`: a bot should be able to record what it
            learns about a user from conversation.
          '';
        };

        stateFiles = lib.mkOption {
          type = lib.types.attrsOf (lib.types.oneOf [ lib.types.path lib.types.str ]);
          default = { };
          example = { "groups/telegram/AGENTS.md" = lib.literalExpression "./household-skeleton.md"; };
          description = ''
            Files seeded once into mutable paths via tmpfiles `C`
            (copy-if-absent). Key = path relative to dataDir, value = source.

            This is for shared memory the agent is meant to maintain - e.g. the
            bot-scope `groups/<channel>/AGENTS.md` when the bot rewrites the
            file as its notes change. If the content must never be edited by
            the agent, declare it in `readOnlyFiles` instead; a path may not be
            in both.
          '';
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
        firewallTCPPorts = lib.mkOption {
          type = lib.types.listOf lib.types.port;
          default = [ ];
          description = "Host firewall ports to open. The module does NOT parse the (free-form) config to infer them: if config binds web_host = 0.0.0.0, list the web_port here yourself."
          ;
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
      globalAgentsTarget = "${ic.dataDir}/groups/AGENTS.md";
      # Every ancestor directory of a dataDir-relative path, excluding the
      # file itself ("groups/telegram/AGENTS.md" -> "groups",
      # "groups/telegram").
      parentsOf =
        rel: let
          dirs = lib.init (lib.splitString "/" rel);
        in map (i: lib.concatStringsSep "/" (lib.take i dirs)) (lib.range 1 (builtins.length dirs));
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
          SECRET=$(cat ${lib.escapeShellArg (toString s.file)}) \
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
        (
          let
            overlap = lib.filter (n: ic.stateFiles ? ${n}) (lib.attrNames ic.readOnlyFiles);
          in
          {
            assertion = overlap == [ ];
            message = ''
              microclaw-${name}: declared both readOnlyFiles and stateFiles,
              which cannot both hold: ${lib.concatStringsSep ", " overlap}.
              Use readOnlyFiles for Nix-owned governance (kernel read-only bind),
              stateFiles for copy-if-absent mutable scaffolding.
            '';
          }
        )
      ];

      warnings = [ ];

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
          ${lib.optionalString (ic.globalAgents != null) ''
            if [ ! -s ${lib.escapeShellArg (toString ic.globalAgents)} ]; then
              echo "${unit}: globalAgents is empty; the global governance scope must not be blank" >&2
              exit 1
            fi
            # Reachable when systemd auto-created the destination, or when a
            # previous config seeded real content there. If this file is
            # non-empty AND differs from the Nix source, the bind is not
            # taking effect and the agent would silently read stale content
            # instead of the reviewed governance file. Fail loudly rather
            # than run on the wrong policy.
            _ga_target=${lib.escapeShellArg globalAgentsTarget}
            if [ -e "$_ga_target" ] && ! cmp -s "$_ga_target" ${lib.escapeShellArg (toString ic.globalAgents)}; then
              echo "${unit}: globalAgents target has content differing from the Nix source;" >&2
              echo "${unit}: the read-only bind is not in effect, so the agent would read stale governance." >&2
              exit 1
            fi
          ''}
          ${lib.optionalString (ic.readOnlyFiles != { }) ''
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (
                dst: src:
                  ''
                  if [ ! -s ${lib.escapeShellArg (toString src)} ]; then
                    echo "${unit}: read-only governance file ${dst} is empty" >&2
                    exit 1
                  fi
                ''
              ) ic.readOnlyFiles
            )}
          ''}
          ${secretInjects}

          ${lib.optionalString (ic.webPasswordFile != null) ''
            pw_file=${lib.escapeShellArg (toString ic.webPasswordFile)}
            if [ ! -s "$pw_file" ]; then
              echo "${unit}: $pw_file missing or empty, keeping the current Web UI password" >&2
            else
              ${lib.escapeShellArg microclawExe} --config "$cfg_file" web password "$(cat "$pw_file")"
            fi
          ''}

          # Plane 2 seeds: personas + skills, NEVER clobbering - agent-owned
          # volatile data must survive restarts.
          ${seedDirCmds}

          # Declarative per-instance skill gating (merged,
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
# Kernel-enforced read-only governance: writes fail EROFS, unlink
        # fails EBUSY, and the mount source is the store path, so the live
        # file is always exactly the Nix version - including against an
        # unsandboxed `bash`, which microclaw#501 does not guard.
        #
        # NOTE on the target existing on the host: systemd creates a missing
        # bind destination itself, as a 0-byte root-owned placeholder. So
        # <dataDir>/groups/AGENTS.md normally DOES exist on the host as an
        # empty mountpoint and its content there is meaningless - it is
        # shadowed by the bind inside the unit's mount namespace. Read the
        # effective file with
        #   nsenter -t $(systemctl show -p MainPID --value ${unit}) -m \
        #     cat <target>
        # A non-empty host-side file is the anomaly worth investigating, not
        # an empty one; preStart below treats a stale non-empty host target
        # as a hard error, since it means the bind is not in effect and the
        # agent would read pre-governance content instead.
        #
        # The bind lists are concatenated rather than being two attribute sets
        # because `//` overwrites. lib.mkIf is unusable here too - the whole
        # attrset is a single module definition, so only optionalAttrs is
        # honoured.
        // lib.optionalAttrs ((ic.globalAgents != null) || (ic.readOnlyFiles != { })) {
          BindReadOnlyPaths =
            lib.optionals (ic.globalAgents != null) [
              "${toString ic.globalAgents}:${globalAgentsTarget}"
            ]
            ++ lib.mapAttrsToList (
              dst: src: "${toString src}:${ic.dataDir}/${dst}"
            ) ic.readOnlyFiles;
        };

        # A store-content change alone would not restart the unit (the config
        # is a symlink), so trigger explicitly.
        restartTriggers =
          [ staticConfig ]
          ++ lib.optionals (ic.globalAgents != null) [ ic.globalAgents ]
          ++ lib.mapAttrsToList (dst: src: src) ic.readOnlyFiles;

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
          # NB: no hardcoded "<dataDir>/groups" rule. globalAgents' parent is
          # derived from its actual target below, so a non-default target
          # still gets its parent created and there is a single source of
          # truth. The old hardcoded rule also silently masked a missing
          # globalAgents entry in the derived parent list.
        ]
        ++ lib.mapAttrsToList (
          dst: src: "C ${ic.dataDir}/${dst} 0644 ${cfg.user} ${cfg.group} - ${toString src}"
        ) ic.stateFiles
        # systemd creates missing bind-mount destinations itself, but as
        # root-owned 0755. Pre-create every parent directory of a read-only
        # file as the service user instead, so the agent can still add
        # siblings next to a governance file it may not modify.
        #
        # globalAgents is included here because it is bound separately from
        # readOnlyFiles (see service.bindMounts) and would otherwise be missed:
        # without this, <dataDir>/groups ends up root-owned and the agent
        # cannot create bot/chat-scope AGENTS.md next to it.
        ++ map (
          d: "d ${ic.dataDir}/${d} 0755 ${cfg.user} ${cfg.group} -"
        ) (
          lib.unique (
            lib.flatten (
              (lib.mapAttrsToList (dst: _: parentsOf dst) ic.readOnlyFiles)
              ++ lib.optional (ic.globalAgents != null) (
                parentsOf (lib.removePrefix "${ic.dataDir}/" globalAgentsTarget)
              )
            )
          )
        );

      networking.firewall.allowedTCPPorts = ic.firewallTCPPorts;

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

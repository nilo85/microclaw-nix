# microclaw-nix

A reusable NixOS module for running [MicroClaw](https://github.com/microclaw/microclaw)
agent instances (Telegram bots with file tools and learned skills) as
hardened systemd services. It encodes the operational lessons from a
multi-user household deployment:

- **Nix owns the runtime config.** The mutable config is reseeded from the
  Nix render on *every* start, then secrets are injected. (Seed-once
  policies silently swallow config changes - including tool policy - until
  the next full reseed. Yes, this happened.)
- **Secrets are file paths, never values.** The module reads secret FILES
  at `preStart` (`sops-nix`, `agenix`, `systemd-credentials`, anything that
  drops a readable file). Nothing about your secret store leaks into this
  flake.
- **The package is a parameter.** This flake does not pin or build
  MicroClaw itself, and contains zero host-specific information.

## The three state planes

| plane         | file(s)                                   | semantics                                                                 |
| ------------- | ----------------------------------------- | ------------------------------------------------------------------------- |
| constitution  | `<dataDir>/groups/AGENTS.md`              | kernel-read-only bind from a **store path**: writes fail `EROFS`, unlink `EBUSY`, content is always exactly the Nix version |
| personality   | `souls/`, `skills/`, per-chat `SOUL.md`   | seeded `cp -n` (no-clobber); agent-owned volatile data; **never overwritten by Nix once present** |
| state         | `groups/<channel>/AGENTS.md`, chat memory | seeded once via tmpfiles `C` (copy-if-absent); fully mutable afterwards   |

Why a kernel lock for the constitution? MicroClaw's own file tools bypass
its `write_memory` scope gates and happily rewrite governance files
([microclaw/microclaw#501](https://github.com/microclaw/microclaw/issues/501)).
`BindReadOnlyPaths` fixes this at the mount layer: an agent cannot rewrite
the rules it is governed by, and a NixOS switch is the only update path.
Consequence: the bind target exists only inside the unit's mount
namespace; on the host, `<dataDir>/groups/AGENTS.md` is absent. Read it
with:

```sh
nsenter -t $(systemctl show -p MainPID --value microclaw-<name>) -m \
  cat /var/lib/microclaw-<name>/groups/AGENTS.md
```

## Usage

```nix
# your host flake
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.microclaw-nix = { url = "github:nilo85/microclaw-nix"; inputs.nixpkgs.follows = "nixpkgs"; };
  outputs = i: {
    nixosConfigurations.host = i.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        i.microclaw-nix.nixosModules.microclaw
        ./configuration.nix
      ];
    };
  };
}
```

```nix
# configuration.nix
{ config, pkgs, ... }:
{
  microclaw.package = pkgs.microclaw; # however you obtain it

  microclaw.instances.assistant = {
    dataDir = "/var/lib/microclaw-assistant";
    constitution = ./constitution.md;

    config = {
      llm = { ... };                      # your provider/model block
      channels.telegram = {
        enabled = true;
        allowed_user_ids = [ 12345 ];
        accounts.assistant = {
          soul_path = "/var/lib/microclaw-assistant/souls/assistant.md";
          default = true;
        };
      };
      server.tool_policy = { mode = "plan_only"; max_risk = "low"; };
    };

    secrets = [
      { key = ".channels.telegram.accounts.assistant.bot_token";
        file = "/run/secrets/assistant-token"; }
      { key = ".channels.telegram.accounts.assistant.bot_username";
        file = "/run/secrets/assistant-botname"; }
    ];

    seedDirs   = [ { src = ./souls; dst = "souls"; } ];
    stateFiles = { "groups/telegram/AGENTS.md" = ./shared-state-skeleton.md; };
    disabledSkills = [ "xlsx" ];          # per-instance gating
  };
}
```

Each entry of `microclaw.instances` becomes `microclaw-<name>.service`.
Multiple bots = multiple entries: separate dataDirs, separate units,
separate personas; one shared package/user. See `examples/nixos-host.nix`.

## Option reference (`microclaw.instances.<name>`)

| option              | type                              | default                | notes                                                            |
| ------------------- | --------------------------------- | ---------------------- | ---------------------------------------------------------------- |
| `dataDir`           | str                               | -                      | must be under `/var/lib` (systemd `StateDirectory`)              |
| `workingDir`        | str                               | `/srv/microclaw-<name>` | seeded via tmpfiles                                             |
| `config`            | attrs                             | `{}`                   | secret-free config; `data_dir`/`working_dir` injected if absent   |
| `constitution`      | null or path                      | `null`                 | bind-mounted read-only onto `<dataDir>/groups/AGENTS.md`          |
| `secrets`           | `[{ key file }]`                  | `[]`                   | `key` = yq path into the mutable config; empty file ⇒ unit fails |
| `webPasswordFile`   | null or path                      | `null`                 | re-applied every start (hash lives in the state db)              |
| `seedDirs`          | `[{ src dst }]`                   | `[]`                   | `cp -n`; agent-owned afterwards                                  |
| `stateFiles`        | `{ rel = path }`                  | `{}`                   | tmpfiles `C`: copy-if-absent seeding                             |
| `disabledSkills`    | `[str]`                           | `[]`                   | merged into `runtime/skills_state.json`, never replaced          |
| `firewallTCPPorts`  | `[port]`                          | `[]`                   | opened on the host; the module does not parse your config to infer them |
| `serviceAfter/Wants/BindsTo` | `[str]`                  | `[]`                   | ordering to your LLM proxy units                                 |
| `extraPath`         | `[package]`                       | `[]`                   | e.g. `git`, `curl` if the agent can shell out                    |

Top level: `microclaw.package` (required with instances), `binaryName`,
`user`/`group` (shared, static system account), `createAccounts`,
`instances`.

## Caveats

- Hardening is strong but not paranoid-grade: `ProtectSystem=full`,
  `PrivateTmp`, `NoNewPrivileges`, etc., yet the unit reaches the network
  and any HTTP-reachable model endpoint. Re-evaluate if MicroClaw gains
  exec/shell tools; the bind-mounted constitution is the one guarantee the
  agent cannot break by itself.
- `lib.mkIf`-style conditions in `preStart` fail fast: an empty secret file
  blocks the unit *before* the config is seeded, so a rotation miss cannot
  produce a silently broken bot.
- The instances option must never feed a whole-module `config = ...`
  assignment (module-system self-cycle; `nix flake check` covers this).
- tmpfiles seeding uses the static user; with `createAccounts = false`
  (DynamicUser) adjust ownership expectations for `stateFiles`.

## Development

```sh
nix flake check          # eval test + string invariants + enforced assertions
```

`test/eval-example.nix` asserts the security invariants (bind path, seed
order, fail-fast, skill gating, restart triggers) against stubbed NixOS
namespaces.

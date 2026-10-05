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
  **Note (2026-10-03):** `pkgs.microclaw` is not in nixpkgs yet — the
  packaging PR [NixOS/nixpkgs#498144](https://github.com/NixOS/nixpkgs/pull/498144)
  is still open. To use this today, source the PR branch as a flake input:

  ```nix
  # flake inputs (a plain nixpkgs branch; don't `follows` your own nixpkgs)
  nixpkgs-microclaw.url = "github:everettjf/nixpkgs/microclaw-init";

  # then in your config:
  microclaw.package =
    inputs.nixpkgs-microclaw.legacyPackages.${system}.microclaw;
  ```

  Once #498144 merges and reaches your channel, the input disappears and
  `microclaw.package = pkgs.microclaw;` just works.

## Upstream terminology

This module uses MicroClaw's own vocabulary, so a host config reads the same
way as the engine's docs. Upstream keeps a memory hierarchy under
`<dataDir>/groups/`, where the single file name `AGENTS.md` serves several
scopes (`MemoryManager` in
`crates/microclaw-engine/src/internal/storage/memory.rs`):

| scope      | path                                       | upstream fn                 |
| ---------- | ------------------------------------------ | --------------------------- |
| global     | `groups/AGENTS.md`                         | `global_memory_path`        |
| bot        | `groups/<channel>/AGENTS.md`                | `bot_memory_path`           |
| chat       | `groups/<channel>/<chat_id>/AGENTS.md`      | `chat_memory_path`          |
| user model | `groups/<channel>/<chat_id>/USER.md`        | `chat_user_model_path`      |
| soul       | `<config.soul_path>`, default `SOUL.md` in the data dir | `config.soul_path` |
| soul layers| `<config.souls_dir>/<layer>/*.md`           | `config.souls_dir`          |

Upstream calls `AGENTS.md`, `SOUL.md` and `USER.md` the **governance files**
and refuses to let the generic file tools rewrite them
([#501](https://github.com/microclaw/microclaw/issues/501),
`GOVERNANCE_FILE_NAMES` in `internal/tool_runtime/path_guard.rs`).

| option           | file(s)                                  | semantics                                                                 |
| ---------------- | ---------------------------------------- | ------------------------------------------------------------------------- |
| `globalAgents`   | `<dataDir>/groups/AGENTS.md`             | kernel-read-only bind from a **store path**: writes fail `EROFS`, unlink `EBUSY`, content is always exactly the Nix version |
| `readOnlyFiles`  | any governance file, e.g. `groups/<channel>/AGENTS.md` | same mechanism, for the scopes `globalAgents` does not cover |
| `seedDirs`       | `souls/`, `skills/`                      | seeded `cp -n` (no-clobber); agent-owned volatile data; **never overwritten by Nix once present** |
| `stateFiles`     | bot-scope `AGENTS.md`, per-chat scaffolding | seeded once via tmpfiles `C` (copy-if-absent); fully mutable afterwards   |

Why a kernel lock? #501 blocks `write_file` / `edit_file` only — its own
changelog notes that "`bash` without the sandbox still runs as the service
user". `BindReadOnlyPaths` closes that at the mount layer, so governance
content is identical to the Nix version by construction and a NixOS switch is
the only update path. Consequence: the bind target exists only inside the
unit's mount namespace; on the host, `<dataDir>/groups/AGENTS.md` is absent.
Read it with:

```sh
nsenter -t $(systemctl show -p MainPID --value microclaw-<name>) -m \
  cat /var/lib/microclaw-<name>/groups/AGENTS.md
```

What is deliberately **not** locked: files describing a human. A bot should
be able to record what it learns about a user from conversation, so
`seedDirs` covers the per-user soul layer and per-chat `SOUL.md` / `USER.md`
stay writable. Locking those would make you edit Nix and rebuild for a fact
the bot just learned from you. In a multi-user deployment the thing to pin is
the shared bot-scope `AGENTS.md`, via `readOnlyFiles`, so one user's
conversation cannot edit governance the others read.

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
    globalAgents = ./global-AGENTS.md;

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
    # Nix-owned governance: kernel-read-only, cannot be rewritten even by bash
    readOnlyFiles = { "groups/telegram/AGENTS.md" = ./groups/telegram/AGENTS.md; };
    # Mutable scaffolding: seeded once, then the agent owns it
    stateFiles   = { "groups/telegram/cleaning.md" = ./shared-skeleton.md; };
    disabledSkills = [ "xlsx" ];          # per-instance gating
  };
}
```

Each entry of `microclaw.instances` becomes `microclaw-<name>.service`.
Multiple bots = multiple entries: separate dataDirs, separate units,
separate personas; one shared package/user. See `examples/nixos-host.nix`.

**Don't hardcode secret paths.** Ask your secret manager where it actually
puts the file: with sops-nix, `file = config.sops.secrets.<name>.path;`
instead of guessing `/run/secrets/<name>` (the module function already
takes `config`; `config.sops.secrets.<name>.path` is the authoritative
location and keeps working if sops-nix's layout or your `path` option
ever changes).

## Option reference (`microclaw.instances.<name>`)

| option              | type                              | default                | notes                                                            |
| ------------------- | --------------------------------- | ---------------------- | ---------------------------------------------------------------- |
| `dataDir`           | str                               | -                      | must be under `/var/lib` (systemd `StateDirectory`)              |
| `workingDir`        | str                               | `/srv/microclaw-<name>` | seeded via tmpfiles                                             |
| `config`            | attrs                             | `{}`                   | secret-free config; `data_dir`/`working_dir` injected if absent   |
| `globalAgents`      | null or path                      | `null`                 | bind-mounted read-only onto `<dataDir>/groups/AGENTS.md` (global scope) |
| `secrets`           | `[{ key file }]`                  | `[]`                   | `key` = yq path into the mutable config; empty file ⇒ unit fails |
| `webPasswordFile`   | null or path                      | `null`                 | re-applied every start (hash lives in the state db)              |
| `seedDirs`          | `[{ src dst }]`                   | `[]`                   | `cp -n`; agent-owned afterwards                                  |
| `readOnlyFiles`     | `{ rel = path }`                  | `{}`                   | kernel read-only bind for other governance scopes; a path may not be in `stateFiles` too |
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
  exec/shell tools; the bind-mounted governance files are the one guarantee
  the agent cannot break by itself.
- `lib.mkIf`-style conditions in `preStart` fail fast: an empty secret file
  blocks the unit *before* the config is seeded, so a rotation miss cannot
  produce a silently broken bot.
- The instances option must never feed a whole-module `config = ...`
  assignment (module-system self-cycle; `nix flake check` covers this).
- tmpfiles seeding uses the static user; with `createAccounts = false`
  (DynamicUser) adjust ownership expectations for `stateFiles`.
- `systemd.tmpfiles.rules` are only applied on boot and on
  `systemd-tmpfiles-setup.service`, which the generated units do not
  `After=`. A unit can therefore start before its `d` rules have run on a
  given boot, which is why every bind destination is also safe to create by
  systemd itself and why the parent directories are additionally pre-created
  here as the service user.
- `globalAgents` and `readOnlyFiles` destinations exist on the *host* as
  0-byte root-owned mountpoints (systemd creates them). Their host-side
  content is meaningless; the real file only exists inside the unit mount
  namespace. `preStart` fails the unit if a destination holds content that
  differs from its Nix source, since that means the bind is not in effect.

## Development

```sh
nix flake check          # eval test + string invariants + enforced assertions
```

`test/eval-example.nix` asserts the security invariants (bind path, seed
order, fail-fast, skill gating, restart triggers) against stubbed NixOS
namespaces.

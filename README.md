# flake-skills

A Nix flake framework for distributing, propagating, and sharing agent skills
across teams and projects.

Define skills once.
Pull them into any project with a one-liner.
Use anyone's distributed skills.

## Quick Start

### 1. Create your shared skills repo

```
acme-skills/
├── flake.nix
└── skills/
    ├── docx/
    │   └── SKILL.md
    └── pdf/
        ├── SKILL.md
        └── script.sh
```

The `flake.nix` for defining and sharing your skills is minimal:

```nix
{
  description = "ACME Corp agent skills";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-skills.url = "github:papercomputeco/flake-skills";
  };

  outputs = { self, nixpkgs, flake-skills }:
    flake-skills.lib.mkSkillsFlake {
      inherit nixpkgs;
      skillsSrc = ./skills;
    };
}
```

Add all `SKILL.md` files (and any supporting scripts,
templates, etc.) into `skills/<name>/` and they're automatically discovered.
Commit them to source control and push. They're now shared!

### 2. Use shared skills in a project

```nix
{
  description = "My project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    acme-skills.url = "github:acme-corp/acme-skills";
    acme-skills.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, acme-skills }:
    let
      system = "x86_64-linux";
      pkgs   = nixpkgs.legacyPackages.${system};
      skills = acme-skills.lib;
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        name = "my-project";

        shellHook = skills.mkSkillsHook {
          skills = [ "docx" "pdf" "acme-style-guide" ];
        };
      };
    };
}
```

### 3. Enter the dev shell

```bash
$ nix develop
Syncing skills to .agents/skills/
  active skills: docx, pdf, acme-style-guide
```

Your `.agents/skills/` directory now contains exactly the skills you listed.
It's synced on every shell entry, stale skills are cleaned up, and the
directory is added to `.git/info/exclude` automatically.

## Composite Skill Flakes

You can pull in an upstream skill pack and layer your own skills on
top. Local skills win on name collisions, so you can override community
definitions with your own:

```nix
{
  description = "ACME Corp composite skills";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-skills.url = "github:papercomputeco/flake-skills";
    community-skills.url = "github:someorg/community-agent-skills";
    community-skills.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-skills, community-skills }:
    flake-skills.lib.mkSkillsFlake {
      inherit nixpkgs;
      skillsSrc = ./skills;
      extraSkillsFlakes = [ community-skills ];
    };
}
```

This gives you every skill from the input `community-skills` plus everything in your
local `./skills/`. If both define a `docx` skill, yours takes precedence.

Composition is transitive: if `community-skills` itself composes from another
upstream flake, those skills are automatically included via `allSkillSources`.

## Configuration Tips

**Custom target directory** — if your agent reads from a different path (***cough*** Claude ***cough***):

```nix
shellHook = skills.mkSkillsHook {
  skills = [ "docx" ];
  targetDir = ".cursor/skills";
};
```

**Commit skills to git** — if you want them version-controlled in the
consumer repo:

```nix
shellHook = skills.mkSkillsHook {
  skills = [ "docx" ];
  gitExclude = false;
};
```

**Pin versions** — consumers lock via `flake.lock`. Update with:

```bash
nix flake update acme-skills
```

**Typo protection** — referencing a non-existent skill name fails at Nix dev shell eval-time:

```
error: flake-skills: unknown skill "doccx". Available: acme-api-patterns, acme-style-guide, docx, pdf
```

## Running Tests

The framework includes end-to-end tests as Nix flake checks:

```bash
nix flake check
```

This runs tests for skill discovery, selection, composition, transitive
composition, and shell hook generation.

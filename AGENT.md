## Do

* Use flake-parts
* Write checks

## Don't

* Do not install new dependencies without approval or force lib consumers to 
  consume new packages

## How flake-skills works

```
flake-skills (framework)
└── acme-team-skills
        ├── project
        ├── another-project
        └── yet-another-project
```

Three layers:

1. **flake-skills** — This repo. A library that provides `mkSkillsFlake` for propagating skills.
2. **Consumer skills** — A thin flake wrapping a `skills/` directory.
   One function call. This is where a team's `SKILL.md` files live.
3. **Projects** — Each project pulls in the shared skills flake and
   picks the skills it needs by name. `nix develop` syncs them into
   `.agents/skills/`.

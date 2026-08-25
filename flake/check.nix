# flake/check.nix
#
# End-to-end checks for flake-skills
# Run with: nix flake check

{ inputs, ... }:

{
  perSystem = { pkgs, system, ... }:
    let
      lib = import ../lib;

      # -----------------------------------------------------------------
      # Helper: create a mock skills directory in the Nix store
      # -----------------------------------------------------------------
      mkMockSkillsDir = skills:
        pkgs.runCommandLocal "mock-skills" {} (
          builtins.concatStringsSep "\n" (
            [ "mkdir -p $out" ]
            ++ map (s: ''
              mkdir -p $out/${s.name}
              cat > $out/${s.name}/SKILL.md <<'SKILL_EOF'
              ${s.content}
              SKILL_EOF
            '') skills
          )
        );

      # -----------------------------------------------------------------
      # Mock skill directories
      # -----------------------------------------------------------------
      localSkills = mkMockSkillsDir [
        { name = "coding-style"; content = "# Coding Style\nUse consistent formatting."; }
        { name = "api-patterns"; content = "# API Patterns\nFollow REST conventions."; }
        { name = "testing";      content = "# Testing\nWrite tests for all features."; }
      ];

      upstreamSkills = mkMockSkillsDir [
        { name = "community-docs"; content = "# Community Docs\nDocument everything."; }
        { name = "coding-style";   content = "# Community Coding Style\nThis should be overridden."; }
      ];

      # -----------------------------------------------------------------
      # Build flake outputs from the mock skills
      # -----------------------------------------------------------------
      nixpkgs = inputs.nixpkgs;

      localFlake = lib.mkSkillsFlake {
        inherit nixpkgs;
        skillsSrc = localSkills;
        supportedSystems = [ system ];
      };

      # Simulate an upstream flake
      upstreamFlake = lib.mkSkillsFlake {
        inherit nixpkgs;
        skillsSrc = upstreamSkills;
        supportedSystems = [ system ];
      };

      # Composed flake: local + upstream, local wins on collision
      composedFlake = lib.mkSkillsFlake {
        inherit nixpkgs;
        skillsSrc = localSkills;
        extraSkillsFlakes = [ upstreamFlake ];
        supportedSystems = [ system ];
      };

    in {
      checks = {
        # -------------------------------------------------------------
        # Test 1: basic skill discovery and package build
        # -------------------------------------------------------------
        basic = pkgs.runCommandLocal "check-basic" {} ''
          pkg="${localFlake.packages.${system}.all-skills}"

          test -f "$pkg/coding-style/SKILL.md"  || { echo "FAIL: coding-style missing"; exit 1; }
          test -f "$pkg/api-patterns/SKILL.md"  || { echo "FAIL: api-patterns missing"; exit 1; }
          test -f "$pkg/testing/SKILL.md"        || { echo "FAIL: testing missing"; exit 1; }

          grep -q "Use consistent formatting" "$pkg/coding-style/SKILL.md" \
            || { echo "FAIL: coding-style content wrong"; exit 1; }

          echo "PASS: basic skill discovery and packaging"
          mkdir -p $out && touch $out/passed
        '';

        # -------------------------------------------------------------
        # Test 2: skill selection (subset)
        # -------------------------------------------------------------
        selection = pkgs.runCommandLocal "check-selection" {} ''
          pkg="${localFlake.lib.mkSkillsPackage {
            inherit pkgs;
            skills = [ "coding-style" "testing" ];
          }}"

          test -f "$pkg/coding-style/SKILL.md" || { echo "FAIL: coding-style missing"; exit 1; }
          test -f "$pkg/testing/SKILL.md"       || { echo "FAIL: testing missing"; exit 1; }
          test ! -d "$pkg/api-patterns"         || { echo "FAIL: api-patterns should not be present"; exit 1; }

          echo "PASS: skill selection works"
          mkdir -p $out && touch $out/passed
        '';

        # -------------------------------------------------------------
        # Test 3: composition — upstream + local, local wins on collision
        # -------------------------------------------------------------
        composition = pkgs.runCommandLocal "check-composition" {} ''
          pkg="${composedFlake.packages.${system}.all-skills}"

          test -f "$pkg/coding-style/SKILL.md"   || { echo "FAIL: coding-style missing"; exit 1; }
          test -f "$pkg/api-patterns/SKILL.md"   || { echo "FAIL: api-patterns missing"; exit 1; }
          test -f "$pkg/testing/SKILL.md"         || { echo "FAIL: testing missing"; exit 1; }
          test -f "$pkg/community-docs/SKILL.md" || { echo "FAIL: community-docs missing"; exit 1; }

          grep -q "Use consistent formatting" "$pkg/coding-style/SKILL.md" \
            || { echo "FAIL: local coding-style should override upstream"; exit 1; }

          grep -q "Document everything" "$pkg/community-docs/SKILL.md" \
            || { echo "FAIL: upstream community-docs content wrong"; exit 1; }

          echo "PASS: composition with local override"
          mkdir -p $out && touch $out/passed
        '';

        # -------------------------------------------------------------
        # Test 4: skill names are correct
        # -------------------------------------------------------------
        skill-names = pkgs.runCommandLocal "check-skill-names" {} ''
          ${let
            names = composedFlake.skillNames;
            expected = [ "api-patterns" "coding-style" "community-docs" "testing" ];
            namesStr = builtins.concatStringsSep "," names;
            expectedStr = builtins.concatStringsSep "," expected;
          in ''
            actual="${namesStr}"
            expected="${expectedStr}"
            if [ "$actual" = "$expected" ]; then
              echo "PASS: skill names match ($actual)"
            else
              echo "FAIL: expected '$expected', got '$actual'"
              exit 1
            fi
          ''}
          mkdir -p $out && touch $out/passed
        '';

        # -------------------------------------------------------------
        # Test 5: shellHook generation (verify valid bash)
        # -------------------------------------------------------------
        shell-hook = pkgs.runCommandLocal "check-shell-hook" {} ''
          hook=${pkgs.writeText "hook.sh" (composedFlake.lib.mkSkillsHook {
            skills = [ "coding-style" "testing" ];
            targetDir = ".test-skills";
          })}

          ${pkgs.bash}/bin/bash -n "$hook" \
            || { echo "FAIL: generated shellHook has bash syntax errors"; exit 1; }

          grep -q "coding-style" "$hook" || { echo "FAIL: hook missing coding-style"; exit 1; }
          grep -q "testing" "$hook"       || { echo "FAIL: hook missing testing"; exit 1; }
          grep -q ".test-skills" "$hook"  || { echo "FAIL: hook missing custom targetDir"; exit 1; }

          # Default gitExclude=false should not leave flake-managed skills ignored.
          workdir=$(mktemp -d)
          mkdir -p "$workdir/.test-skills"
          printf '%s\n' '# Managed by flake-skills -- do not edit' '/coding-style/' > "$workdir/.test-skills/.gitignore"
          (cd "$workdir" && ${pkgs.bash}/bin/bash "$hook" 2>/dev/null)

          test ! -f "$workdir/.test-skills/.gitignore" \
            || { echo "FAIL: default hook should remove managed .gitignore"; exit 1; }
          test -f "$workdir/.test-skills/coding-style/SKILL.md" \
            || { echo "FAIL: default hook should sync coding-style"; exit 1; }
          test -f "$workdir/.test-skills/testing/SKILL.md" \
            || { echo "FAIL: default hook should sync testing"; exit 1; }
          rm -rf "$workdir"

          echo "PASS: shellHook generation"
          mkdir -p $out && touch $out/passed
        '';

        # -------------------------------------------------------------
        # Test 7: gitExclude writes per-skill .gitignore
        # -------------------------------------------------------------
        git-exclude = pkgs.runCommandLocal "check-git-exclude" {} ''
          hook=${pkgs.writeText "hook-git.sh" (composedFlake.lib.mkSkillsHook {
            skills = [ "coding-style" "testing" ];
            targetDir = ".test-skills";
            gitExclude = true;
          })}

          ${pkgs.bash}/bin/bash -n "$hook" \
            || { echo "FAIL: generated shellHook has bash syntax errors"; exit 1; }

          # The hook should write a .gitignore inside targetDir
          grep -q ".gitignore" "$hook" \
            || { echo "FAIL: hook should reference .gitignore when gitExclude=true"; exit 1; }

          # It should NOT reference .git/info/exclude (old approach)
          if grep -q "git/info/exclude" "$hook"; then
            echo "FAIL: hook should not use .git/info/exclude"
            exit 1
          fi

          # The hook should contain per-skill ignore entries
          grep -q "/coding-style/" "$hook" \
            || { echo "FAIL: hook should contain /coding-style/ gitignore entry"; exit 1; }
          grep -q "/testing/" "$hook" \
            || { echo "FAIL: hook should contain /testing/ gitignore entry"; exit 1; }

          # Run the hook in a temporary directory and verify the .gitignore
          workdir=$(mktemp -d)
          (cd "$workdir" && ${pkgs.bash}/bin/bash "$hook" 2>/dev/null)
          gitignore="$workdir/.test-skills/.gitignore"

          test -f "$gitignore" \
            || { echo "FAIL: .gitignore not created"; exit 1; }
          grep -qxF '/coding-style/' "$gitignore" \
            || { echo "FAIL: .gitignore missing /coding-style/"; exit 1; }
          grep -qxF '/testing/' "$gitignore" \
            || { echo "FAIL: .gitignore missing /testing/"; exit 1; }
          grep -qxF '/.gitignore' "$gitignore" \
            || { echo "FAIL: .gitignore should ignore itself"; exit 1; }

          # Verify that non-selected skills are NOT in the .gitignore
          if grep -qxF '/api-patterns/' "$gitignore"; then
            echo "FAIL: .gitignore should not contain non-selected skill /api-patterns/"
            exit 1
          fi

          rm -rf "$workdir"
          echo "PASS: gitExclude writes per-skill .gitignore"
          mkdir -p $out && touch $out/passed
        '';

        # -------------------------------------------------------------
        # Test 6: allSkillSources exposed for transitive composition
        # -------------------------------------------------------------
        transitive = pkgs.runCommandLocal "check-transitive" {} ''
          ${let
            hasAll = builtins.hasAttr "coding-style" composedFlake.allSkillSources
                  && builtins.hasAttr "api-patterns" composedFlake.allSkillSources
                  && builtins.hasAttr "testing" composedFlake.allSkillSources
                  && builtins.hasAttr "community-docs" composedFlake.allSkillSources;
          in
            if hasAll then ''
              echo "PASS: allSkillSources exposes all composed skills"
            '' else ''
              echo "FAIL: allSkillSources missing expected keys"
              exit 1
            ''
          }
          mkdir -p $out && touch $out/passed
        '';
      };
    };
}

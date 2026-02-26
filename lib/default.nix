# lib/default.nix
#
# flake-skills lib
#
# This file is imported directly (no arguments). All nixpkgs.lib usage happens
# inside mkSkillsFlake, where the consumer-provided `nixpkgs` is available.
# This means the framework flake itself has zero runtime dependency on nixpkgs.

let

  # ---------------------------------------------------------------------------
  # discoverSkills : path -> [ string ]
  #
  # Given a directory path, return the names of all subdirectories.
  # ---------------------------------------------------------------------------
  discoverSkills = dir:
    let
      entries = builtins.readDir dir;
      dirs = builtins.filter
        (name: entries.${name} == "directory")
        (builtins.attrNames entries);
    in
    dirs;

  # ---------------------------------------------------------------------------
  # validateSkills : [ string ] -> [ string ] -> [ string ]
  #
  # Filters requested skills, throwing on unknown names.
  # ---------------------------------------------------------------------------
  validateSkills = allSkillNames: requested:
    builtins.filter (name:
      if builtins.elem name allSkillNames
      then true
      else throw (
        "flake-skills: unknown skill \"" + name + "\". "
        + "Available: " + builtins.concatStringsSep ", " allSkillNames
      )
    ) requested;

  # ---------------------------------------------------------------------------
  # mkSkillsPackage : attrset -> [ string ] -> { pkgs, skills? } -> derivation
  #
  # Builds a derivation containing the selected skills as store paths.
  # ---------------------------------------------------------------------------
  mkSkillsPackage = allSkillSources: allSkillNames:
    { pkgs, skills ? allSkillNames }:
    let
      selectedSkills = validateSkills allSkillNames skills;
    in
    pkgs.runCommandLocal "flake-skills" {} (
      builtins.concatStringsSep "\n" (
        [ "mkdir -p $out" ]
        ++ map (name:
          "cp -r ${allSkillSources.${name}} $out/${name}"
        ) selectedSkills
      )
    );

  # ---------------------------------------------------------------------------
  # mkSkillsHook : attrset -> [ string ] -> { skills?, targetDir?, gitExclude? } -> string
  #
  # Returns a shellHook string that syncs selected skills into a local directory.
  # Portable across macOS (BSD) and Linux (GNU).
  # ---------------------------------------------------------------------------
  mkSkillsHook = allSkillSources: allSkillNames:
    {
      skills ? allSkillNames,
      targetDir ? ".agents/skills",
      gitExclude ? true,
    }:
    let
      selectedSkills = validateSkills allSkillNames skills;

      # Copy each selected skill into the target directory.
      # Uses rm + cp instead of GNU-only `cp -rTf` for macOS compatibility.
      copyCommands = builtins.concatStringsSep "\n" (
        map (name: ''
          rm -rf "${targetDir}/${name}"
          cp -r ${allSkillSources.${name}} "${targetDir}/${name}"
          chmod -R u+w "${targetDir}/${name}"
        '') selectedSkills
      );

      # Build a bash associative array for exact-match skill lookups.
      # This avoids regex injection issues with skill names containing
      # metacharacters and correctly handles the empty-skills case
      # (all existing skills get removed).
      keepEntries = builtins.concatStringsSep "\n" (
        map (name: ''  ["${name}"]=1'') selectedSkills
      );

      cleanupBlock = ''
        declare -A _flake_skills_keep=(
        ${keepEntries}
        )
        if [ -d "${targetDir}" ]; then
          for existing in "${targetDir}"/*/; do
            [ -d "$existing" ] || continue
            name="$(basename "$existing")"
            if [ -z "''${_flake_skills_keep[$name]+x}" ]; then
              rm -rf "$existing"
              echo "  removed deselected skill: $name"
            fi
          done
        fi
        unset _flake_skills_keep
      '';

      # Build the content for targetDir/.gitignore: one entry per synced
      # skill plus the .gitignore itself.  Written as a fully-managed
      # file so it always reflects exactly the current set of
      # flake-managed skills, while leaving any hand-written skills in
      # the same directory tracked by git.
      gitignoreContent = builtins.concatStringsSep "\\n" (
        [ "# Managed by flake-skills -- do not edit" ]
        ++ map (name: "/${name}/") selectedSkills
        ++ [ "/.gitignore" ]
      );

      gitExcludeBlock =
        if gitExclude then ''
          printf '%b\n' '${gitignoreContent}' > "${targetDir}/.gitignore"
        '' else "";

      skillList = builtins.concatStringsSep ", " selectedSkills;

    in ''
      echo "Syncing skills to ${targetDir}/"
      mkdir -p "${targetDir}"
      ${copyCommands}
      ${cleanupBlock}
      ${gitExcludeBlock}
      echo "  active skills: ${skillList}"
    '';

in

{
  # ---------------------------------------------------------------------------
  # mkSkillsFlake
  #
  # The sole public entrypoint of flake-skills.
  # Produces a full flake output set from a directory of skills.
  #
  # Arguments:
  #   skillsSrc         (required) - Path to a directory of skill subdirectories.
  #   nixpkgs           (required) - The consumer's nixpkgs input.
  #   extraSkillsFlakes (optional) - List of upstream skill flakes to compose.
  #   supportedSystems  (optional) - Systems to generate per-system outputs for.
  #
  # Returns: { lib, skillNames, skillsSrc, allSkillSources, packages, devShells }
  # ---------------------------------------------------------------------------
  mkSkillsFlake = {
    skillsSrc,
    nixpkgs,
    extraSkillsFlakes ? [],
    supportedSystems ? [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ],
  }:
    let
      lib = nixpkgs.lib;

      forAllSystems = f:
        lib.genAttrs supportedSystems (system:
          f { pkgs = nixpkgs.legacyPackages.${system}; inherit system; });

      # Discover local skills (any subdirectory of skillsSrc)
      localSkillNames = discoverSkills skillsSrc;

      # Merge in skills from upstream flakes.
      # Uses allSkillSources from each upstream flake so that transitive
      # composition works correctly (upstream-of-upstream skills are included).
      upstreamSkillSources = builtins.foldl' (acc: flake:
        acc // flake.allSkillSources
      ) {} extraSkillsFlakes;

      # Local skills map each name to its subdirectory path
      localSkillSources = builtins.listToAttrs (
        map (name: {
          inherit name;
          value = skillsSrc + "/${name}";
        }) localSkillNames
      );

      # Local skills take precedence over upstream (allows overrides)
      allSkillSources = upstreamSkillSources // localSkillSources;
      allSkillNames = builtins.attrNames allSkillSources;

      boundLib = {
        skillNames = allSkillNames;
        inherit allSkillSources;
        mkSkillsHook = mkSkillsHook allSkillSources allSkillNames;
        mkSkillsPackage = mkSkillsPackage allSkillSources allSkillNames;
      };

    in {
      lib = boundLib;

      # Exposed for downstream composition via extraSkillsFlakes
      skillNames = allSkillNames;
      skillsSrc = skillsSrc;
      inherit allSkillSources;

      packages = forAllSystems ({ pkgs, ... }: {
        all-skills = boundLib.mkSkillsPackage { inherit pkgs; skills = allSkillNames; };
      });

      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.mkShell {
          name = "skills-dev";
          shellHook = boundLib.mkSkillsHook {
            skills = allSkillNames;
          };
        };
      });
    };
}

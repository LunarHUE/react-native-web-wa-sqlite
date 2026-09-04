{
  description = "lh-wa-sqlite - wa-sqlite WASM build + VFS/Expo packages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Emscripten is pinned separately: packages/wasm/flake.lock builds the
    # checked-in dist/*.wasm with this exact nixpkgs rev (emscripten 4.0.23).
    # nixos-unstable has since moved to emscripten 6.x, whose codegen/link
    # flags differ, so `make` at the repo root uses the same compiler the
    # published artifacts were built with. Bump this together with
    # packages/wasm/flake.lock, never on its own.
    nixpkgs-emscripten.url = "github:NixOS/nixpkgs/80bdc1e5ce51f56b19791b52b2901187931f5353";

    claude-code = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    codex-cli-nix = {
      url = "github:sadjow/codex-cli-nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-emscripten,
      flake-utils,
      claude-code,
      codex-cli-nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;

          config.allowUnfree = true;

          overlays = [
            claude-code.overlays.default
            codex-cli-nix.overlays.default
          ];
        };

        # See the nixpkgs-emscripten input comment above.
        emscripten = (import nixpkgs-emscripten { inherit system; }).emscripten;

        # Node toolchain. package.json pins `packageManager: pnpm@10.6.1` and
        # `turbo ^2.8.13`; nixpkgs tracks the latest 10.x/2.x of each, which is
        # what the workspace actually resolves against.
        corePackages = with pkgs; [
          nodejs_22
          pnpm_10
          turbo
        ];

        # Everything the root Makefile shells out to while building
        # dist/wa-sqlite*.{mjs,wasm}:
        #   emcc          - compiles sqlite3.c + src/*.c to WASM (README: 3.1.61+)
        #   make/curl     - drives the build, fetches the sqlite tarball and
        #                   extension-functions.c
        #   openssl       - `openssl dgst -sha3-256` integrity check on
        #                   extension-functions.c
        #   tcl           - sqlite's own `configure --enable-all && make sqlite3.c`
        #                   needs tclsh to generate the amalgamation
        #   python3       - emscripten's toolchain scripts
        #   gnused/gnutar/gzip/unzip - tarball extraction and post-processing
        # The C compiler used to build sqlite's host tools (lemon, mkkeywordhash)
        # comes from mkShell's default stdenv.
        wasmBuildPackages = with pkgs; [
          emscripten
          gnumake
          curl
          openssl
          tcl
          python3
          gnused
          gnutar
          gzip
          unzip
        ];

        # packages/vfs runs @web/test-runner against a real browser
        # (chromeLauncher + --enable-features=WebAssemblyExperimentalJSPI).
        # Not available on darwin in nixpkgs; use a locally installed Chrome there.
        browserPackages = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
          pkgs.chromium
        ];

        devOnlyPackages = with pkgs; [
          git
          git-lfs
          gh
          jq
          nix-bash-completions

          pkgs.claude-code
          codex-cli-nix.packages.${system}.default
        ];

        # emscripten's nix store cache is read-only, but emcc needs to write to it.
        # Seed a writable copy (once per toolchain version) so the first build
        # does not have to recompile libc/libc++ from scratch. Kept outside the
        # tree so `make clean-cache`/`make spotless` do not blow it away.
        emscriptenEnv = ''
          export EM_CACHE="''${XDG_CACHE_HOME:-$HOME/.cache}/emscripten/${emscripten.version}"
          if [ "$(cat "$EM_CACHE/.nix-source" 2>/dev/null)" != "${emscripten}" ]; then
            rm -rf "$EM_CACHE"
            mkdir -p "$EM_CACHE"
            cp -r --no-preserve=mode "${emscripten}/share/emscripten/cache/." "$EM_CACHE/"
            echo "${emscripten}" > "$EM_CACHE/.nix-source"
          fi
        '';

        chromeEnv = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
          export CHROME_PATH="${pkgs.chromium}/bin/chromium"
        '';

        # pnpm must not try to download 10.6.1 to match package.json's
        # packageManager field -- the nix pnpm is the toolchain.
        pnpmEnv = {
          COREPACK_ENABLE_STRICT = "0";
          npm_config_manage_package_manager_versions = "false";
          npm_config_package_manager_strict = "false";
        };

        # No postinstall script should fetch its own browser binary.
        browserDownloadEnv = {
          PUPPETEER_SKIP_DOWNLOAD = "1";
          PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
        };
      in
      {
        devShells.default = pkgs.mkShell (
          pnpmEnv
          // browserDownloadEnv
          // {
            name = "lh-wa-sqlite-dev";

            packages = corePackages ++ wasmBuildPackages ++ browserPackages ++ devOnlyPackages;

            shellHook = ''
              ${emscriptenEnv}
              ${chromeEnv}
              echo "lh-wa-sqlite devShell: node $(node --version), pnpm $(pnpm --version), $(emcc --version | head -1)"
            '';
          }
        );

        # Toolchain for CI (`nix develop .#ci -c <cmd>`): the same build and
        # test tools as the dev shell, minus the interactive extras. Pure --
        # the runner image needs nothing but nix.
        devShells.ci = pkgs.mkShell (
          pnpmEnv
          // browserDownloadEnv
          // {
            name = "lh-wa-sqlite-ci";

            packages = corePackages ++ wasmBuildPackages ++ browserPackages ++ [ pkgs.git ];

            shellHook = ''
              ${emscriptenEnv}
              ${chromeEnv}
            '';
          }
        );

        # Shell for just `make` / `make clean && make` with no node tooling.
        devShells.wasm = pkgs.mkShell {
          name = "lh-wa-sqlite-wasm";

          packages = wasmBuildPackages;

          shellHook = emscriptenEnv;
        };

        formatter = pkgs.nixfmt-tree;
      }
    );
}

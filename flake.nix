{
  description = "PixelCad - KiCad fork dev environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      forSystems = f: nixpkgs.lib.genAttrs [ "aarch64-linux" "x86_64-linux" ]
        (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forSystems (pkgs:
      let
        # KiCad wants ONE template dir holding both the worksheet templates and
        # the global sym-lib-table / fp-lib-table seeds -- but those ship in three
        # different library packages.  Merge them, as the nixpkgs wrapper does.
        templateDir = pkgs.symlinkJoin {
          name = "KiCad_template_dir";
          paths = [
            "${pkgs.kicad.libraries.templates}/share/kicad/template"
            "${pkgs.kicad.libraries.symbols}/share/kicad/template"
            "${pkgs.kicad.libraries.footprints}/share/kicad/template"
          ];
        };
      in
      {
        default = pkgs.mkShell {
          # kicad.base is the real (unwrapped) KiCad derivation; pulls in
          # wxWidgets, boost, OCCT, ngspice, protobuf, nng, cmake, etc.
          inputsFrom = [ pkgs.kicad.base ];

          packages = with pkgs; [
            ninja
            ccache
            gdb
            clang-tools # clangd for IDE
            opencascade-occt # 7.9.x; kicad.base still pins 7.6.2
            glib # gsettings, for checking the schema path below
            gsettings-desktop-schemas
            adwaita-icon-theme
          ];

          shellHook = ''
            export CMAKE_CXX_COMPILER_LAUNCHER=ccache
            # kicad.base (10.0.x) pins OCCT 7.6.2, but KiCad master needs 7.9's
            # TKDEIGES/TKDESTEP.  Point FindOCC.cmake at 7.9 explicitly.
            export OCC_INCLUDE_DIR=${pkgs.opencascade-occt}/include/opencascade
            export OCC_LIBRARY_DIR=${pkgs.opencascade-occt}/lib

            # A source build compiles KICAD_DATA to /usr/local/share/kicad, which
            # does not exist -- so schemas, templates and resources are unfindable.
            # Borrow the packaged data tree instead of installing one.
            export KICAD_STOCK_DATA_HOME=${pkgs.kicad.base}/share/kicad

            # Libraries live in separate repos and are never part of a source build.
            # master is 10.99, so the versioned prefix is KICAD10_ and the packaged
            # KiCad 10 libraries match.  Same values the nixpkgs kicad wrapper sets.
            export KICAD10_SYMBOL_DIR=${pkgs.kicad.libraries.symbols}/share/kicad/symbols
            export KICAD10_FOOTPRINT_DIR=${pkgs.kicad.libraries.footprints}/share/kicad/footprints
            export KICAD10_3DMODEL_DIR=${pkgs.kicad.libraries.packages3d}/share/kicad/3dmodels
            export KICAD10_TEMPLATE_DIR=${templateDir}

            # GTK's file chooser reads GSettings, and GLib *aborts* (not warns) when
            # a schema is missing -- so opening any file dialog from a bare dev shell
            # kills the app in g_settings_set_property.  Put the compiled schemas and
            # icon theme on XDG_DATA_DIRS, as the nixpkgs kicad wrapper does.
            export XDG_DATA_DIRS="${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.adwaita-icon-theme}/share:$XDG_DATA_DIRS"

            # An install tree keeps every .kiface in one lib dir; a build tree puts
            # each in its own module subdir, so the project manager cannot find them.
            # This is KiCad's own switch for that: kiway then looks in ../<module>/.
            export KICAD_RUN_FROM_BUILD_DIR=1

            # Caveat of that switch: GetStockDataPath() prefers the build root over
            # KICAD_STOCK_DATA_HOME, which would lose translations and stock scripting
            # plugins, so the packaged data has to be mirrored into the build root.
            #
            # Deliberately NOT done here.  A shell hook runs before every build and
            # cannot know whether CMake has yet written the files it owns: the build
            # generates schemas/api.v1.schema.json, and the packaged tree contains that
            # name too.  Staging first puts a store symlink exactly where CMake is about
            # to write, and the build dies on "Read-only file system" -- and because
            # `cp -r` copies the store's read-only directory modes, the staged tree
            # cannot even be cleaned up without a chmod first.  ./run-kicad.sh stages it
            # after the build, which is the only point where the two cannot collide.
            export KICAD_PACKAGED_DATA=${pkgs.kicad.base}/share/kicad

            echo "KiCad dev shell.  Run ./run-kicad.sh to launch.  Configure with:"
            # FindOCC.cmake uses find_path(), which does not read an env var of the same
            # name, so OCC_INCLUDE_DIR has to be passed on the command line.
            echo "  cmake -S kicad -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \\"
            echo "    -DOCC_INCLUDE_DIR=\"\$OCC_INCLUDE_DIR\" -DOCC_LIBRARY_DIR=\"\$OCC_LIBRARY_DIR\""
            echo "  cmake --build build"
          '';
        };
      });
    };
}

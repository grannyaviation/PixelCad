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
            echo "KiCad dev shell. Configure with:"
            echo "  cmake -S kicad -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
            echo "  cmake --build build"
          '';
        };
      });
    };
}

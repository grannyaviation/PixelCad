{
  description = "PixelCad - KiCad fork dev environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      forSystems = f: nixpkgs.lib.genAttrs [ "aarch64-linux" "x86_64-linux" ]
        (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forSystems (pkgs: {
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
            echo "KiCad dev shell. Configure with:"
            echo "  cmake -S kicad -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
            echo "  cmake --build build"
          '';
        };
      });
    };
}

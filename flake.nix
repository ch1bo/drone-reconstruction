{
  description = "Drone 3D Reconstruction Development Environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true; # Required for CUDA
            cudaSupport = true;
          };
        };

        # Python with base dependencies for Nerfstudio
        python = pkgs.python311;
        pythonWithDeps = python.withPackages (ps: with ps; [
          pip
          torch-bin
          torchvision-bin
        ]);

        # Install Nerfstudio into Nix store using pip
        nerfstudioEnv = pkgs.stdenv.mkDerivation {
          name = "nerfstudio-env";

          buildInputs = [ pythonWithDeps ];

          # No source needed, we'll download via pip
          dontUnpack = true;

          buildPhase = ''
            mkdir -p $out

            # Install nerfstudio and dependencies using pip
            ${pythonWithDeps}/bin/pip install \
              --prefix=$out \
              --no-cache-dir \
              --no-warn-script-location \
              nerfstudio
          '';

          installPhase = ''
            # Create wrapper scripts for nerfstudio commands
            mkdir -p $out/bin

            # Wrap Python scripts to use correct PYTHONPATH
            for script in $out/bin/*; do
              if [ -f "$script" ]; then
                mv "$script" "$script.unwrapped"
                cat > "$script" << EOF
#!/bin/sh
export PYTHONPATH="$out/${python.sitePackages}:\$PYTHONPATH"
exec "$script.unwrapped" "\$@"
EOF
                chmod +x "$script"
              fi
            done
          '';
        };

      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Python with PyTorch
            pythonWithDeps

            # Nerfstudio from Nix store
            nerfstudioEnv

            # Core dependencies
            colmap  # Structure-from-Motion
            ffmpeg-full  # Video processing

            # CUDA toolkit for GPU acceleration
            cudaPackages.cudatoolkit
            cudaPackages.cudnn

            # Utility tools
            exiftool  # DJI metadata extraction
            imagemagick  # Image processing

            # Development tools
            git
            cmake
            pkg-config

            # Libraries for CUDA and rendering
            stdenv.cc.cc.lib
            zlib
            libGL
            libGLU
            xorg.libX11
            xorg.libXext
            xorg.libXrender
          ];

          shellHook = ''
            echo "🚁 Drone 3D Reconstruction Environment"
            echo "======================================"
            echo ""

            # Set up CUDA environment variables
            export CUDA_HOME="${pkgs.cudaPackages.cudatoolkit}"
            export LD_LIBRARY_PATH="${pkgs.cudaPackages.cudatoolkit}/lib:${pkgs.cudaPackages.cudnn}/lib:${pkgs.stdenv.cc.cc.lib}/lib:$LD_LIBRARY_PATH"

            # Add nerfstudio to PATH and PYTHONPATH
            export PATH="${nerfstudioEnv}/bin:$PATH"
            export PYTHONPATH="${nerfstudioEnv}/${python.sitePackages}:$PYTHONPATH"

            # Create directory structure
            mkdir -p input data outputs exports scripts

            echo "Environment ready! Available commands:"
            echo "  • ns-process-data  - Process drone video"
            echo "  • ns-train         - Train 3D models"
            echo "  • ns-viewer        - View results"
            echo "  • ns-export        - Export meshes/point clouds"
            echo "  • colmap           - COLMAP SfM tool"
            echo "  • ffmpeg           - Video processing"
            echo "  • exiftool         - Extract DJI metadata"
            echo ""
            echo "GPU: NVIDIA CUDA support enabled"
            echo "Python: $(python --version)"
            echo ""
          '';
        };
      }
    );
}

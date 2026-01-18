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
        pythonDeps = with pkgs.python3Packages; [
          torch
          tiny-cuda-nn
        ];

        # Install Nerfstudio into Nix store using pip
        nerfstudio = pkgs.callPackage
          (pkgs.python3Packages.buildPythonApplication rec {
            pname = "nerfstudio";
            version = "1.1.5";
            pyproject = true;

            src = pkgs.fetchPypi {
              inherit pname version;
              hash = "sha256-w9j9JyCFZeIDHksMifgut4GZIH1RlHVfW2yPQeAvTPk=";
            };

            build-system = with pkgs.python3Packages; [ setuptools ];
            dependencies = pythonDeps;
          })
          { };

      in
      {
        packages.nerfstudio = nerfstudio;

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Python with PyTorch and nerfstudio pre-installed
            (python3withPackages (ps: pythonDeps ++ [ nerfstudio ]))

            # Core dependencies
            colmap # Structure-from-Motion
            ffmpeg-full # Video processing

            # CUDA toolkit for GPU acceleration
            cudaPackages.cudatoolkit
            cudaPackages.cudnn

            # Utility tools
            exiftool # DJI metadata extraction
            imagemagick # Image processing

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
            export PATH="${nerfstudio}/bin:$PATH"
            export PYTHONPATH="${nerfstudio}/${python.sitePackages}:$PYTHONPATH"

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

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
            allowUnfree = true;
            cudaSupport = true;
          };
        };

        # Python with dependencies for GPS processing
        pythonDeps = with pkgs.python3Packages; [
          # GPS integration dependencies
          numpy # For numerical operations
          scipy # For similarity transform estimation
          srt # SRT subtitle parsing (for DJI telemetry)
        ];

        # Nerfstudio build commented out - use on GPU machine later
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
            dependencies = with pkgs.python3Packages; [ torch tiny-cuda-nn ];
          })
          { };
      in
      {
        packages.nerfstudio = nerfstudio;

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Python with GPS processing dependencies
            (python3.withPackages (ps: pythonDeps))

            # Core dependencies
            colmap # Structure-from-Motion
            ffmpeg-full # Video processing

            # Utility tools
            exiftool # DJI metadata extraction
            imagemagick # Image processing

            # Development tools
            git
          ];

          shellHook = ''
            echo "🚁 Drone 3D Reconstruction Environment (COLMAP + GPS)"
            echo "======================================================="
            echo ""
            echo "Environment ready! Available commands:"
            echo "  • colmap           - COLMAP SfM tool"
            echo "  • ffmpeg           - Video processing"
            echo "  • exiftool         - Extract DJI metadata"
            echo "  • python scripts/  - GPS integration scripts"
            echo ""
            echo "Python: $(python --version)"
            echo ""
            echo "Note: Nerfstudio build is disabled for faster setup."
            echo "      Use this environment for GPS data processing and COLMAP."
            echo "      Train NeRF models on GPU machine later."
            echo ""
          '';
        };
      }
    );

  nixConfig = {
    extra-substituters = [ "https://cache.nixos-cuda.org" ];
    extra-trusted-public-keys = [ "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=" ];
  };
}

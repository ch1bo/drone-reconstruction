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

        # Older version needed for a few nerfstudio dependencies
        python = pkgs.python312;

        # Python with dependencies for GPS processing
        pythonDeps = with python.pkgs; [
          # GPS integration dependencies
          numpy # For numerical operations
          scipy # For similarity transform estimation
          srt # SRT subtitle parsing (for DJI telemetry)

          # Nerfstudio dependencies
          # Installed via nix for the cuda support
          torch
          tiny-cuda-nn
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          name = "droneReconstructionVenv";
          venvDir = "./.venv";
          buildInputs = with pkgs; [
            # Core dependencies
            colmap # Structure-from-Motion
            ffmpeg-full # Video processing
            exiftool # DJI metadata extraction
            imagemagick # Image processing
            git
            # Build dependencies
            pkg-config
            cmake
            # A Python interpreter including the 'venv' module is required to
            # bootstrap the environment.
            python
            # This executes some shell code to initialize a venv in $venvDir
            # before dropping into the shell
            python.pkgs.venvShellHook
          ]
          # More python packages (picked up by shell hook)
          ++ pythonDeps;

          # Install nerfstudio via pip as many dependencies are not in nixpkgs
          postVenvCreation = ''
            unset SOURCE_DATE_EPOCH
            pip install --upgrade pip
            git submodule update --init
            cd nerfstudio
            pip install -e .
          '';

          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
            pkgs.libx11
            pkgs.libudev-zero
            pkgs.libglvnd
            pkgs.glib
            pkgs.xorg.libxcb
          ];
        };
      }
    );

  nixConfig = {
    extra-substituters = [ "https://cache.nixos-cuda.org" ];
    extra-trusted-public-keys = [ "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=" ];
  };
}

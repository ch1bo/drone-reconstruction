{
  description = "Drone 3D Reconstruction Development Environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (system: {
      devShells.default =
        let
          pkgs = import nixpkgs {
            inherit system;
            config = { };
          };

          # Fix null meta_data_ crash in patch_match_stereo.
          #
          # The nixpkgs openimageio.patch introduces OIIOMetaData::Clone() calls
          # in Bitmap's copy constructor and copy assignment operator without
          # guarding against null meta_data_. A default-constructed Bitmap() has
          # meta_data_ == nullptr. Copying such an empty Bitmap (which happens
          # when model.images is vector-copied in patch_match.cc) crashes with:
          #   'dynamic_cast<OIIOMetaData*>(meta_data)' Must be non NULL
          # This matches the fix on colmap main branch (post PR #3459).
          colmap-fixed = pkgs.colmap.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [
              ./patches/colmap-bitmap-oiio-copy.patch
            ];
          });

          python = pkgs.python3;

          # Python with dependencies for GPS processing
          pythonDeps = [
            # GPS integration dependencies
            python.pkgs.numpy # For numerical operations
            python.pkgs.scipy # For similarity transform estimation
            python.pkgs.srt # SRT subtitle parsing (for DJI telemetry)
          ];
        in
        pkgs.mkShell {
          name = "droneReconstructionColmapOnly";
          buildInputs =
            with pkgs;
            [
              colmap-fixed # Structure-from-Motion
              ffmpeg-full # Video processing
            ]
            ++ pythonDeps;
        };

      # Full pipeline including all cuda dependencies and an impure venv
      devShells.full =
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              # These two settings result in a lot of compilation
              cudaSupport = true;
              cudaCapabilities = [ "8.9" ]; # RTX 40XX cards
            };
          };

          # Older version needed for a few nerfstudio dependencies
          python = pkgs.python312;

          # Patch tiny-cuda-nn to respect TCNN_CACHE_PATH environment variable
          tiny-cuda-nn-patched = python.pkgs.tiny-cuda-nn.overrideAttrs (oldAttrs: {
            patches = (oldAttrs.patches or [ ]) ++ [
              ./patches/tiny-cuda-nn-cache-env.patch
            ];
          });

          # See comment in devShells.default for explanation.
          colmap-fixed = pkgs.colmap.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [
              ./patches/colmap-bitmap-oiio-copy.patch
            ];
          });

          # Python with dependencies for GPS processing
          pythonDeps = [
            # GPS integration dependencies
            python.pkgs.numpy # For numerical operations
            python.pkgs.scipy # For similarity transform estimation
            python.pkgs.srt # SRT subtitle parsing (for DJI telemetry)

            # TODO: re-enable Nerfstudio dependencies
            # python.pkgs.torch
            # tiny-cuda-nn-patched
          ];
        in
        pkgs.mkShell {
          name = "droneReconstructionFull";
          venvDir = "./.venv";
          buildInputs =
            with pkgs;
            [
              # Core dependencies
              colmap-fixed # Structure-from-Motion
              ffmpeg-full # Video processing
              exiftool # DJI metadata extraction
              imagemagick # Image processing
              git
              # Build dependencies
              pkg-config
              cmake
              # CUDA for building tiny-cuda-nn from source
              cudaPackages.cudatoolkit
              cudaPackages.cudnn
              # A Python interpreter including the 'venv' module is required to
              # bootstrap the environment.
              python
              # This executes some shell code to initialize a venv in $venvDir
              # before dropping into the shell
              # TODO: re-enable python.pkgs.venvShellHook
            ]
            # More python packages (picked up by shell hook)
            ++ pythonDeps;

          # Install nerfstudio via pip as many dependencies are not in nixpkgs
          postVenvCreation = ''
            set -e
            unset SOURCE_DATE_EPOCH
            pip install --upgrade pip

            # Install nerfstudio
            git submodule update --init
            cd nerfstudio
            pip install -e .
          '';

          postShellHook = ''
            # Set writable cache for patched tiny-cuda-nn
            export TCNN_CACHE_PATH="$PWD/cache/tinycudann"
            mkdir -p "$TCNN_CACHE_PATH"
          '';

          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
            pkgs.libx11
            pkgs.libudev-zero
            pkgs.libglvnd
            pkgs.glib
            pkgs.xorg.libxcb
          ];
        };
    });

  nixConfig = {
    extra-substituters = [ "https://cache.nixos-cuda.org" ];
    extra-trusted-public-keys = [ "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=" ];
  };
}

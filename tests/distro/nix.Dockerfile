FROM nixos/nix:latest
# Only root can add store paths in this image, so run.sh starts this leg as root.
LABEL somewm.distro.user=root
ENV NIX_CONFIG="experimental-features = nix-command flakes"
# container.sh calls awk and sed, which the image lacks.
RUN nix profile install nixpkgs#gawk nixpkgs#gnused

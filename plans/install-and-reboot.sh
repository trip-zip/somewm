#!/bin/bash
# Build and install somewm
cd ~/git/github/somewm
ninja -C build || exit 1
sudo make install || exit 1
echo "Installed successfully."

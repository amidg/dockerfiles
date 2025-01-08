#!/bin/bash

# Install C++ stuff
apt update -qqy
echo "Installing C/C++ development tools"
apt install -qqy \
    clang \
    gcc \
    g++ \
    cmake \
    ninja-build \
    build-essential \
    cppcheck \
    doxygen \
    ccache \
    gcovr

# Install Python dev stuff
echo "Installing Python development tools"
apt install -qqy \
    python3 \
    python3-dev \
    python3-pip \
    python3-full \
    python3-distutils \
    python3-venv \
    python3-argcomplete \
    python3-setuptools \
    python3-wheel \
    ninja-build

# Install Meson
echo "Installing Meson Build System and packaing tools"
pip3 install meson
apt install -qqy \
    dh-make \
    file \
    gdb \
    ruby \
    jq

# cannot install anything after this, only for cleaning
#sudo rm -rf /var/lib/apt/lists/*

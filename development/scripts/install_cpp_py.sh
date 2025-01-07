#!/bin/bash

# Install C++ stuff
apt update -qqy
apt install -qqy \
    clang \
    gcc \
    g++ \
    cmake \
    ninja-build \
    build-essential \
    python3 \
    python3-pip \
    cppcheck \
    doxygen \
    ccache \
    gcovr

# cannot install anything after this, only for cleaning
#sudo rm -rf /var/lib/apt/lists/*

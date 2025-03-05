#!/bin/bash

# Install C++ stuff
echo "Installing GNU C/C++ development tools"
apt update -qqy && \
apt install -qqy --no-install-recommends \
    software-properties-common \
    build-essential \
    gcc \
    g++ \
    gdb \
    cmake \
    ninja-build \
    build-essential \
    cppcheck \
    doxygen \
    ccache \
    gcovr

# Install Clang
echo "Installing LLVM"
apt install -qqy --no-install-recommends \
    clang-format \
    clang-tidy \
    clang-tools \
    clang \
    clangd \
    libc++-dev \
    libc++1 \
    libc++abi-dev \
    libc++abi1 \
    libclang-dev \
    libclang1 \
    liblldb-dev \
    libllvm-ocaml-dev \
    libomp-dev \
    libomp5 \
    lld \
    lldb \
    llvm-dev \
    llvm-runtime \
    llvm \
    python3-clang 

# Install Python dev stuff
echo "Installing Python development tools"
apt install -qqy --no-install-recommends \
    python3 \
    python3-dev \
    python3-pip \
    python3-full \
    python3-venv \
    python3-argcomplete \
    python3-setuptools \
    python3-wheel \
    ninja-build

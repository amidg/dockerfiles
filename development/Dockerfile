# default Ubuntu image
FROM ubuntu:24.04 AS base

# setup linux system
WORKDIR /app
COPY scripts/ .
RUN bash ./setup_ubuntu.sh

# setup programming tools
RUN bash ./install_cpp_py.sh


# NVDA Image
FROM nvidia/cuda:12.6.3-devel-ubuntu24.04 AS gpu_base
# setup linux system
WORKDIR /app
COPY scripts/ .
RUN bash ./setup_ubuntu.sh

# setup programming tools
RUN bash ./install_cpp_py.sh

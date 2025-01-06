# default Ubuntu image
FROM ubuntu:24.04

# setup linux system
WORKDIR /app
COPY scripts/ .
RUN bash ./setup_ubuntu.sh

# setup C++
RUN bash ./install_cpp.sh

# setup Python
RUN bash ./install_py.sh


# Nvidia Image
FROM nvidia/cuda:12.6.3-devel-ubuntu24.04
# setup linux system
WORKDIR /app
COPY scripts/ .
RUN bash ./setup_ubuntu.sh

# setup C++
RUN bash ./install_cpp.sh

# setup Python
RUN bash ./install_py.sh

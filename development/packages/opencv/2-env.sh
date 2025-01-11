#!/bin/bash
export OPENCV_VERSION=4.10.0

# build prefixes
# -D CMAKE_INSTALL_PREFIX=$(python3 -c "import sys; print(sys.prefix)") \
# -D OPENCV_PYTHON3_INSTALL_PATH=$(python3 -c "import sysconfig; print(sysconfig.get_path('purelib'))") \

export OPENCV_CMAKE_INSTALL_PREFIX=$(pwd)/usr

export OPENCV_PYTHON3_INSTALL_PATH=$(python3 -c "import sysconfig; print(sysconfig.get_path('purelib'))")

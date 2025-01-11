#!/bin/bash

# prepare environment
# TODO: figure out why dockerfile line 16 is not enough
source $(pwd)/2-env.sh
mkdir -p $OPENCV_CMAKE_INSTALL_PREFIX

# Build OpenCV with C++ and Python support
cd /tmp
git clone --depth=1 --branch $OPENCV_VERSION \
    https://github.com/opencv/opencv.git /tmp/opencv
cd /tmp/opencv
git clone --depth=1 --branch $OPENCV_VERSION \
    https://github.com/opencv/opencv_contrib.git
mkdir build
cd build
cmake -D CMAKE_BUILD_TYPE=RELEASE \
      -D CMAKE_INSTALL_PREFIX=$OPENCV_CMAKE_INSTALL_PREFIX \
      -D OPENCV_EXTRA_MODULES_PATH=$(pwd)/../opencv_contrib/modules \
      -D INSTALL_C_EXAMPLES=ON \
      -D INSTALL_PYTHON_EXAMPLES=ON \
      -D BUILD_EXAMPLES=ON \
      -D OPENCV_ENABLE_NONFREE=ON \
      -D WITH_FREETYPE=OFF \
      -D WITH_GTK=ON \
      -D WITH_OPENGL=ON \
      -D WITH_TBB=ON \
      -D WITH_CUDA=OFF \
      -D WITH_V4L=ON \
      -D ENABLE_FAST_MATH=1 \
      -D OPENCV_GENERATE_PKGCONFIG=ON \
      -D BUILD_opencv_cudacodec=OFF \
      -D OPENCV_PYTHON3_INSTALL_PATH=$OPENCV_PYTHON3_INSTALL_PATH \
      -D PYTHON_EXECUTABLE=$(which python3) \
      -D WITH_GSTREAMER=ON ..
cd /tmp/opencv/build
make -j$(nproc)
make install
ldconfig

# Remove temp files
rm -rf /tmp/opencv

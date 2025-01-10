#!/bin/bash

# ################# #
# Install GStreamer #
# ################# #
apt update -qqy && \
apt install -qqy \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libgstreamer-plugins-bad1.0-dev \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    gstreamer1.0-tools \
    gstreamer1.0-x \
    gstreamer1.0-alsa \
    gstreamer1.0-gl \
    gstreamer1.0-gtk3 \
    gstreamer1.0-qt5 \
    gstreamer1.0-pulseaudio

# ################## #
# Install OpenCV C++ #
# ################## #
# Install Dependencies
apt install -qqy build-essential \
    pkg-config \
    cmake \
    libavcodec-dev \
    libavformat-dev \
    libswscale-dev \
    python3-dev \
    python3-numpy \
    python3-pip \
    python3-venv \
    libtbb-dev \
    libjpeg-dev \
    libpng-dev \
    libtiff-dev \
    libdc1394-dev \
    libgtk-3-dev \
    libfreetype-dev \
    ffmpeg \
    libeigen3-dev \
    libglew-dev \
    libgl1-mesa-dev \
    liblapack-dev \
    libopenblas-dev \
    libv4l-dev \
    zlib1g-dev

# Build OpenCV with C++ and Python support
cd /tmp
git clone --depth=1 --branch $OPENCV_VERSION \
    https://github.com/opencv/opencv.git
cd /tmp/opencv
git clone --depth=1 --branch $OPENCV_VERSION \
    https://github.com/opencv/opencv_contrib.git
mkdir build
cd build
cmake -D CMAKE_BUILD_TYPE=RELEASE \
      -D CMAKE_INSTALL_PREFIX=$(python3 -c "import sys; print(sys.prefix)") \
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
      -D OPENCV_PYTHON3_INSTALL_PATH=$(python3 -c "import sysconfig; print(sysconfig.get_path('purelib'))") \
      -D PYTHON_EXECUTABLE=$(which python3) \
      -D WITH_GSTREAMER=ON ..
cd /tmp/opencv/build
make -j$(nproc)
make install
ldconfig

# Remove temp files
rm -rf /tmp/opencv

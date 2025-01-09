#!/bin/bash

# ################# #
# Install GStreamer #
# ################# #
apt update -qqy && \
apt install -qqy gstreamer1.0* \
    ubuntu-restricted-extras
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libgstreamer-plugins-bad1.0-dev

# ################## #
# Install OpenCV C++ #
# ################## #
# Install Dependencies
apt install -qqy build-essential \
    cmake \
    git \
    libgtk2.0-dev \
    pkg-config \
    libavcodec-dev \
    libavformat-dev \
    libswscale-dev \
    python3-dev \
    python3-numpy \
    libtbb-dev \
    libjpeg-dev \
    libpng-dev \
    libtiff-dev \
    libdc1394-dev \
    libgtk-3-dev \
    libgtk2.0-dev

# Build OpenCV C++
git clone https://github.com/opencv/opencv.git /tmp/opencv
cd /tmp/opencv
git checkout $OPENCV_VERSION
git clone https://github.com/opencv/opencv_contrib.git
cd /tmp/opencv/opencv_contrib
git checkout $OPENCV_VERSION

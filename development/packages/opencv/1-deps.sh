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

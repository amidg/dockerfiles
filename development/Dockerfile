###############
# Base Images #
###############
# Ubuntu 24.04 image
ARG BASE_IMAGE=ubuntu:24.04
FROM $BASE_IMAGE AS base
WORKDIR /app
COPY scripts/ .
RUN bash ./setup_ubuntu.sh
RUN bash ./install_cpp_py.sh


###############
# ROS2 Images #
###############
ARG ROS2_IMAGE=osrf/ros:jazzy-desktop-full
FROM $ROS2_IMAGE AS ros_base
WORKDIR /app
COPY scripts/ .
RUN bash ./setup_ubuntu.sh
RUN bash ./install_cpp_py.sh


##########################
# Computer Vision Images #
##########################


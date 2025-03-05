###############
# Base Images #
###############
# Ubuntu 24.04 image
FROM ubuntu:24.04 AS base
WORKDIR /app
COPY scripts/ .
RUN bash ./setup_ubuntu.sh
RUN bash ./install_cpp_py.sh


###############
# ROS2 Images #
###############
FROM osrf/ros:jazzy-desktop-full AS ros_base
WORKDIR /app
COPY scripts/ .
RUN bash ./setup_ubuntu.sh
RUN bash ./install_cpp_py.sh
RUN bash ./ros2_control.sh
RUN echo "source /opt/ros/$ROS_DISTRO/setup.bash" >> ~/.bashrc


##########################
# Computer Vision Images #
##########################


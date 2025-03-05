#!/bin/bash
# install ros2 control packages
apt update -qqy && \
apt install -qqy \
    ros-$ROS_DISTRO-ros2-control \
    ros-$ROS_DISTRO-ros2-controllers \
    ros-$ROS_DISTRO-gz-ros2-control

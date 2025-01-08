#!/bin/bash

export ROS_DISTRO=jazzy

# Install repos
apt update -qqy && \
apt upgrade -qqy && \
apt install -qqy software-properties-common

add-apt-repository -y universe && \
add-apt-repository -y multiverse

curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | \
    tee /etc/apt/sources.list.d/ros2.list > /dev/null

# Install latest stable ROS2
apt update -qqy && \
apt upgrade -qqy && \
apt install -qqy ros-dev-tools \
    ros-${ROS_DISTRO}-desktop \
    ros-${ROS_DISTRO}-rclcpp-action \
    ros-${ROS_DISTRO}-example-interfaces \
    ros-${ROS_DISTRO}-rosidl-default-generators \
	ros-${ROS_DISTRO}-joint-state-publisher \
    ros-${ROS_DISTRO}-joint-state-publisher-gui \
	ros-${ROS_DISTRO}-xacro \
    python3-rosdep \
	python3-vcstool \
    python3-colcon-common-extensions

# add ROS2 to root's ~/.bashrc
echo "source /opt/ros/jazzy/setup.bash" >> ~/.bashrc

#!/bin/bash

# Set environment variable
export DEBIAN_FRONTEND=noninteractive

# Update package lists quietly and install necessary updates
apt update -qqy
apt upgrade -qqy
apt install -qqy \
    wget \
    curl \
    git

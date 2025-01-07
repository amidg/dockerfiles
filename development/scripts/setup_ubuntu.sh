#!/bin/bash

# Set environment variable
export DEBIAN_FRONTEND=noninteractive
export TZ="Canada/Pacific"
export LANG="en_US.UTF-8"

# Update package lists quietly and install necessary updates
apt update -qqy
apt upgrade -qqy
apt install -qqy \
    wget \
    curl \
    git \
    apt-utils \
    iputils-ping \
    gnupg \
    apt-transport-https \
    ca-certificates \
    nodejs \
    npm \
    vim

# Install locales
apt install -qqy --no-install-recommends locales
ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
echo "$TZ" >/etc/timezone
echo "en_US.UTF-8 UTF-8" >/etc/locale.gen
locale-gen
update-locale LANG=${LANG} LC_ALL=${LANG} LANGUAGE=

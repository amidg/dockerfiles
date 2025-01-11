#!/bin/bash

# install all debian files in the folder
#dpkg -i --force-overwrite ./*.deb
apt install -o Dpkg::Options::="--force-overwrite" -y ./*.deb

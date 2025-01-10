#!/bin/bash

# prepare environment
# TODO: figure out why dockerfile line 16 is not enough
echo "Preparing to build debian package"
source /app/2-env.sh

# build debian package
cd /app
mkdir -p /app/$OPENCV_PYTHON3_INSTALL_PATH
cp -r $OPENCV_PYTHON3_INSTALL_PATH/cv2 /app/$OPENCV_PYTHON3_INSTALL_PATH
dpkg-deb --build . libgusevtech_opencv_${OPENCV_VERSION}.deb

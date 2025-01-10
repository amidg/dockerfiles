# This containerfile allows to build any package in this folder
ARG DEV_CONTAINER_SHA
FROM ghcr.io/amidg/dev_base:$DEV_CONTAINER_SHA AS base
ARG OPENCV_VERSION
ENV OPENCV_VERSION=$OPENCV_VERSION

# copy files from this repo
WORKDIR /app
COPY . .

# install dependencies
RUN bash ./1-deps.sh

# build image
RUN bash ./2-build.sh

# package using debian
WORKDIR /opencv
RUN rm *
RUN mkdir -p opencv-gusevtech/DEBIAN

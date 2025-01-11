# This containerfile allows to build any package in this folder
ARG DEV_CONTAINER_SHA
FROM ghcr.io/amidg/dev_base:$DEV_CONTAINER_SHA AS base
ARG PACKAGE_PATH
ENV PACKAGE_PATH=$PACKAGE_PATH

# copy files from this repo
WORKDIR /app
RUN rm *
COPY $PACKAGE_PATH .

# install package dependencies
RUN bash ./1-deps.sh

# build source code
RUN bash ./3-build.sh

# build debian package
RUN bash ./4-deb.sh

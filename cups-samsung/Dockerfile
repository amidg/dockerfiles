# admin user/password: print/print
FROM olbat/cupsd:stable

# install Samsung printer drivers
COPY uld /uld
WORKDIR /uld
RUN echo "y" | sudo ./install.sh

ARG DEV_CONTAINER_SHA
FROM ghcr.io/amidg/dev_base:$DEV_CONTAINER_SHA AS base

RUN apt install -y apache2
RUN mkdir -p /var/www/html/ubuntu && \
    mkdir /var/run/apache2
RUN echo "source /etc/apache2/envvars" >> ~/.bashrc

RUN chown www-data:www-data /var/www/html/ubuntu
RUN ln -s /var/spool/apt-mirror/mirror/archive.ubuntu.com /var/www/html/ubuntu

ENTRYPOINT ["apache2ctl", "-D", "FOREGROUND"]

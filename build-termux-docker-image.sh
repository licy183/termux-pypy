#!/usr/bin/env bash
set -e

cd termux-docker/
docker build -t termux:aarch64 -f ./Dockerfile --build-arg BOOTSTRAP_ARCH=aarch64 --build-arg SYSTEM_TYPE=arm .
docker build -t termux:i686    -f ./Dockerfile --build-arg BOOTSTRAP_ARCH=i686    --build-arg SYSTEM_TYPE=x86 .
docker build -t termux:x86_64  -f ./Dockerfile --build-arg BOOTSTRAP_ARCH=x86_64  --build-arg SYSTEM_TYPE=x86 .

# When building arm, seccomp should be disabled for convenience, just use ubuntu 14.
docker run -td --rm --privileged --name ubuntu-temp ubuntu:14.04
docker exec -i ubuntu-temp apt-get update
docker exec -i ubuntu-temp apt-get install -yq ca-certificates curl gnupg lsb-release git sudo
docker exec -i ubuntu-temp bash -c "echo \"deb [arch=\$(dpkg --print-architecture)] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" | tee /etc/apt/sources.list.d/docker.list"
docker exec -i ubuntu-temp apt-get update
docker exec -i ubuntu-temp apt-get install -yq --force-yes docker-ce
docker exec -i ubuntu-temp bash -c "nohup dockerd > /dev/null 2>&1 &"
docker exec -i ubuntu-temp git clone https://github.com/termux/termux-docker.git /root/termux-docker
docker exec -i ubuntu-temp docker build -t termux:arm -f /root/termux-docker/Dockerfile --build-arg BOOTSTRAP_ARCH=arm --build-arg SYSTEM_TYPE=arm /root/termux-docker
# Seems that docker COPY cannot process owner and group correctly, change it manually.
docker exec -i ubuntu-temp docker run --rm -u 0 -id --privileged --name termux-arm-tmp termux:arm
docker exec -i ubuntu-temp docker exec -u 0 -i termux-arm-tmp bash -c """
    chown -Rh 0:0 /system && \
    chown -Rh 1000:1000 /data/data/com.termux && \
    chown 1000:1000 /system/etc/hosts /system/etc/static-dns-hosts.txt && \
    find /system -type d -exec chmod 755 \"{}\" \; && \
    find /system -type f -executable -exec chmod 755 \"{}\" \; && \
    find /system -type f ! -executable -exec chmod 644 \"{}\" \; && \
    find /data -type d -exec chmod 755 \"{}\" \; && \
    find /data/data/com.termux/files -type f -o -type d -exec chmod g-rwx,o-rwx \"{}\" \; &&
    cd /data/data/com.termux/files/usr && \
    find ./bin ./lib/apt ./lib/bash ./libexec -type f -exec chmod 700 \"{}\" \;
"""
docker exec -i ubuntu-temp docker export termux-arm-tmp > termux-arm-temp.tar
docker import -c "ENV ANDROID_DATA     /data" \
            -c "ENV ANDROID_ROOT     /system" \
            -c "ENV HOME             /data/data/com.termux/files/home" \
            -c "ENV LANG             en_US.UTF-8" \
            -c "ENV PATH             /data/data/com.termux/files/usr/bin" \
            -c "ENV PREFIX           /data/data/com.termux/files/usr" \
            -c "ENV TMPDIR           /data/data/com.termux/files/usr/tmp" \
            -c "ENV TZ               UTC" \
            -c "WORKDIR /data/data/com.termux/files/home" \
            -c "USER 1000:1000" \
            -c "CMD [\"/data/data/com.termux/files/usr/bin/login\"]" \
            termux-arm-temp.tar termux:arm
docker kill ubuntu-temp

cd $OLDPWD
docker save termux:aarch64 -o termux-aarch64.tar
docker save termux:arm     -o termux-arm.tar
docker save termux:i686    -o termux-i686.tar
docker save termux:x86_64  -o termux-x86_64.tar

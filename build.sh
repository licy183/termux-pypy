#!/usr/bin/env bash
set -e

echo "MAJOR_VERSION =" $MAJOR_VERSION
echo "VERSION =" $VERSION
echo "TARGET_ARCH =" $TARGET_ARCH

# Determine the build platform's arch.
if [ $TARGET_ARCH = "i686" ] || [ $TARGET_ARCH = "arm" ]; then
    BUILD_ARCH=i686
elif [ $TARGET_ARCH = "x86_64" ] || [ $TARGET_ARCH = "aarch64" ]; then
    BUILD_ARCH=x86_64
else
    echo "ERROR: Invalid arch: $TARGET_ARCH" 1>&2
    exit 1
fi

SRC_ARCHIVE_NAME=pypy$MAJOR_VERSION-v$VERSION
BUILD_ARCHIVE_NAME=$SRC_ARCHIVE_NAME-$TARGET_ARCH
REPO_DIR=$(pwd)
TMP_DIR=$(pwd)/tmp
SRC_DIR=$(pwd)/$SRC_ARCHIVE_NAME-src
REMOTE_REPO_DIR=$TERMUX_HOME/repo
REMOTE_TMP_DIR=$REMOTE_REPO_DIR/tmp
REMOTE_SRC_DIR=$REMOTE_REPO_DIR/$SRC_ARCHIVE_NAME-src

setup_build_environment() {
    sudo apt install -yqq sshfs fuse3
    chmod +x remote_cc.py
    ssh-keygen -t rsa -P "" -f ~/.ssh/id_rsa_termux
    sudo mkdir -p $TERMUX_BASE_PREFIX
    sudo chown -R runner:runner $TERMUX_BASE_PREFIX
    sudo chmod -R o+r+w $TERMUX_BASE_PREFIX
    sudo chmod    o+x+w $TERMUX_BASE_PREFIX
}

setup_docker_over_tcp() {
    sudo mkdir -p /etc/systemd/system/docker.service.d
    sudo bash -c 'cat > /etc/systemd/system/docker.service.d/tcp.conf <<EOF
    [Service]
    ExecStart=
    ExecStart=/usr/bin/dockerd -H fd:// -H tcp://127.0.0.1:2375
    EOF'
    sudo systemctl daemon-reload
    sudo systemctl restart docker.service
    curl -v http://127.0.0.1:2375/version
}

apply_termux_ndk_patches() {
    CPWD=$(pwd)
    cd $ANDROID_NDK_LATEST_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot
    git clone https://github.com/termux/termux-packages.git ~/termux-packages
    for f in ~/termux-packages/ndk-patches/*.patch; do
        echo "Applying ndk-patch: $(basename $f)"
        sed "s%\@TERMUX_PREFIX\@%$TERMUX_PREFIX%g" "$f" | \
            sed "s%\@TERMUX_HOME\@%$TERMUX_HOME%g" | \
            patch --silent -p1;
    done
    # libintl.h: Inline implementation gettext functions.
    # langinfo.h: Inline implementation of nl_langinfo().
    cp ~/termux-packages/ndk-patches/{libintl.h,langinfo.h} usr/include
    # Remove <sys/capability.h> because it is provided by libcap.
    # Remove <sys/shm.h> from the NDK in favour of that from the libandroid-shmem.
    # Remove <sys/sem.h> as it doesn't work for non-root.
    # Remove <glob.h> as we currently provide it from libandroid-glob.
    # Remove <iconv.h> as it's provided by libiconv.
    # Remove <spawn.h> as it's only for future (later than android-27).
    # Remove <zlib.h> and <zconf.h> as we build our own zlib.
    # Remove unicode headers provided by libicu.
    rm usr/include/{sys/{capability,shm,sem},{glob,iconv,spawn,zlib,zconf}}.h
    rm usr/include/unicode/{char16ptr,platform,ptypes,putil,stringoptions,ubidi,ubrk,uchar,uconfig,ucpmap,udisplaycontext,uenum,uldnames,ulocdata,uloc,umachine,unorm2,urename,uscript,ustring,utext,utf16,utf8,utf,utf_old,utypes,uvernum,uversion}.h
    rm -rf ~/termux-packages
    cd $CPWD
}

run_containers() {
    # Wrapper container
    docker run -td --network=host --privileged \
                    --name=ndk-wrapper -v /:/rootfs alpine:latest
    # Build container
    docker run -td --network=host --name=termux-$BUILD_ARCH \
                    -v $(pwd):$TERMUX_HOME/repo termux:$BUILD_ARCH
    # Target container
    if [ $TARGET_ARCH = "arm" ]; then
        # XXX: Running 32-bit ARM container needs a custom seccomp profile
        # to remove restrictions from personality() system call. Setting 
        # option `--privileged` may be the easiest way.
        docker run -td --network=host --privileged \
                    --name=termux-$TARGET_ARCH -v $(pwd):$TERMUX_HOME/repo termux:$TARGET_ARCH
    elif [ $TARGET_ARCH = "aarch64" ]; then
        docker run -td --network=host \
                    --name=termux-$TARGET_ARCH -v $(pwd):$TERMUX_HOME/repo termux:$TARGET_ARCH
    fi
}

install_dependicies() {
    BUILD_DEP="binutils binutils-gold clang file patch python3 openssh python2 libffi-static zlib libbz2 libexpat libsqlite-static openssl liblzma-static gdbm readline libcrypt python3 xorgproto python2-static libffi zlib-static libexpat-static libsqlite openssl-static liblzma gdbm-static pkg-config binutils libandroid-posix-semaphore tk"
    for arch in $BUILD_ARCH $TARGET_ARCH
    do
        # Add host
        docker exec -i "termux-$arch" $TERMUX_PREFIX/bin/login -c \
                            "echo foss.heptapod.net >> $TERMUX_PREFIX/etc/static-dns-hosts.txt"
        docker exec -i "termux-$arch" update-static-dns
        docker exec -i "termux-$arch" apt update
        docker exec -i "termux-$arch" apt upgrade -o Dpkg::Options::=--force-confnew -yq
        docker exec -i "termux-$arch" pkg install $BUILD_DEP -yq
        docker exec -i "termux-$arch" python2 -m pip install docker
        SSH_PORT=$(echo $arch | tr -cd "[0-9]\n" | awk '{printf("1%04d",$0)}')
        docker exec -i "termux-$arch" $TERMUX_PREFIX/bin/login -c \
                            "echo 'ListenAddress 0.0.0.0:$SSH_PORT' >> $TERMUX_PREFIX/etc/ssh/sshd_config && sshd"
        docker cp ~/.ssh/id_rsa_termux.pub "termux-$arch":$TERMUX_BASE_PREFIX/home/authorized_keys
        docker exec -i "termux-$arch" $TERMUX_PREFIX/bin/login -c \
                            'cat ~/authorized_keys >> ~/.ssh/authorized_keys && sshd'
    done
    docker exec -i termux-$BUILD_ARCH python2 -m pip install cffi mercurial
}

perform_building() {
    SSH_PORT=$(echo $TARGET_ARCH | tr -cd "[0-9]\n" | awk '{printf("1%04d",$0)}')

    # Make tmp folder.
    mkdir -p $TMP_DIR

    # Setup sshfs.
    sudo sshfs user@127.0.0.1:$TERMUX_BASE_PREFIX $TERMUX_BASE_PREFIX \
                -o port=$SSH_PORT,cache=no,allow_other \
                -o IdentityFile=~/.ssh/id_rsa_termux,StrictHostKeyChecking=no

    # Install cffi use the fake cc.
    docker exec \
        -e CC=$REMOTE_REPO_DIR/remote_cc.py \
        -e TARGET_ARCH=$TARGET_ARCH \
        -e ANDROID_NDK_HOME=$ANDROID_NDK_LATEST_HOME \
        -i termux-$TARGET_ARCH \
            python2 -m pip install cffi

    # Change permission to 777 to make it easy to access by container.
    chmod -R 777 $(pwd)
    chmod 777 $(pwd)

    # Get source code.
    # XXX (2022-02-06): Why 'downloads.python.org' sometimes returns 502? Switch to Mercurial.
    # wget -q https://downloads.python.org/pypy/$SRC_ARCHIVE_NAME-src.zip
    # unzip $SRC_ARCHIVE_NAME-src.zip
    docker exec \
        -i termux-$BUILD_ARCH \
            hg clone -r release-$SRC_ARCHIVE_NAME \
                https://foss.heptapod.net/pypy/pypy $REMOTE_SRC_DIR

    # Apply patches.
    PATCHES=$(find ./patches -mindepth 1 -maxdepth 1 -name *.patch | sort)
    PATCHES+=" "
    PATCHES+=$(find ./patches/${MAJOR_VERSION:0:1} \
                -mindepth 1 -maxdepth 1 -name *.patch | sort)
    shopt -s nullglob
    for patch in $PATCHES; do
        echo "Applying patch: $patch"
        test -f "$patch" && sed \
                -e "s%\@TERMUX_PREFIX\@%$TERMUX_PREFIX%g" \
                "$patch" | docker exec \
                                -w $REMOTE_SRC_DIR \
                                -i termux-$TARGET_ARCH \
                                    patch --silent -p1
    done
    shopt -u nullglob

    # Translate in the container.
    docker exec \
        -w $REMOTE_SRC_DIR/pypy/goal \
        -e TERMUX_BASE_PREFIX=$TERMUX_BASE_PREFIX \
        -e TERMUX_PREFIX=$TERMUX_PREFIX \
        -e ANDROID_NDK_HOME=$ANDROID_NDK_LATEST_HOME \
        -e PYPY_USESSION_DIR=$REMOTE_TMP_DIR \
        -i termux-$BUILD_ARCH \
            python2 -u ../../rpython/bin/rpython \
                --platform=termux-$TARGET_ARCH \
                --source --no-compile -Ojit \
                        targetpypystandalone.py

    # Build using NDK.
    # TODO: Figure out why container's clang hangs.
    cd $REMOTE_TMP_DIR
    cd $(ls -C | awk '{print $1}')/testing_1
    make clean
    make -j $(nproc)

    # Copy build binaries to the path src/pypy/goal.
    if [[ ${MAJOR_VERSION:0:1} = '2' ]]; then
        docker exec \
            -w $(pwd) \
            -i termux-$BUILD_ARCH \
                cp ./pypy-c $REMOTE_SRC_DIR/pypy/goal/pypy-c
        docker exec \
            -w $(pwd) \
            -i termux-$BUILD_ARCH \
                cp ./libpypy-c.so $REMOTE_SRC_DIR/pypy/goal/libpypy-c.so
    elif [[ ${MAJOR_VERSION:0:1} = '3' ]]; then
        docker exec \
            -w $(pwd) \
            -i termux-$BUILD_ARCH \
                cp ./pypy3-c $REMOTE_SRC_DIR/pypy/goal/pypy3-c
        docker exec \
            -w $(pwd) \
            -i termux-$BUILD_ARCH \
                cp ./libpypy3-c.so $REMOTE_SRC_DIR/pypy/goal/libpypy3-c.so
    fi

    # Package to the path repo/tmp
    docker exec \
        -e CC=$REMOTE_REPO_DIR/remote_cc.py \
        -e TARGET_ARCH=$TARGET_ARCH \
        -e ANDROID_NDK_HOME=$ANDROID_NDK_LATEST_HOME \
        -i termux-$TARGET_ARCH \
            python2 $REMOTE_SRC_DIR/pypy/tool/release/package.py \
                --archive-name=$BUILD_ARCHIVE_NAME \
                --targetdir=$REMOTE_TMP_DIR \
                --no-keep-debug --without-_ssl

    # Change permission to 777.
    sudo chmod 777 $TMP_DIR/$BUILD_ARCHIVE_NAME.zip

    # Clean up
    sudo rm -rf $SRC_DIR
    sudo fusermount -zu $TERMUX_BASE_PREFIX
}

# Step 1: Setup build environment.
setup_build_environment

# Step 2: Setup docker over TCP.
setup_docker_over_tcp

# Step 3: Apply termux NDK patches.
# XXX: Maybe better to use a standalone toolchain?
apply_termux_ndk_patches

# Step 4: Run containers.
run_containers

# Step 5: Install build dependicies for every container.
install_dependicies

# Step 6: Perform building.
perform_building

# Step 7: Stop containers.
docker kill $(docker ps -aq)

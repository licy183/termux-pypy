<h1 align="center">Termux-Pypy</h1>

[中文(Chinese) >](https://github.com/licy183/termux-pypy/blob/main/README-zh_CN.md)

## Introdution

This repo provides a way to compile [PyPy](https://pypy.org/) (2/3) on [Termux (Android)](https://github.com/termux/termux-app).

## Usage

### 1. Add Dependicies

Scripts depends on `Docker`, `sshfs`, `fuse3`。

```bash
sudo apt install docker.io sshfs fuse3
```

Of cource, installing the lastest docker is also recommended. See https://docs.docker.com/engine/install/ubuntu/ for detail.

After the installation, add your user to the docker group for convenience of operation later.

```bash
sudo usermod -aG docker user-name
```

Then, setup the binfmt misc for docker, such as using [qus](https://github.com/dbhi/qus).

```bash
docker run --rm --privileged aptman/qus -s -- -p
```

### 2. (Optional) Build Termux Docker Image

This step is optional. You can use the image from official pre-built one. But it provides no ARM image, so if you want to compile PyPy for arm device, you should build the docker image mannually. You can see `build-termux-docker-image.sh` for help.

### 3. Compile

See `build.sh`.

## Implementation

### 0. Introduction

Compiling PyPy contains two part. The first one is translation, which converts RPython source code to C source code, and the second one is compilation, which compiling the C source code to binaries. If we put all these parts on a device or using termux docker and qemu, it will take a long time. On my computer (WSL2-Ubuntu20/i5-8300H/16G), it took about six hours. Besides, clang under termux docker will hang up. Of cource, I commented on https://github.com/termux/termux-packages/issues/1265#issuecomment-957122896 , and provided a way to use clang at a physical device, but the translation is too slow. Actually, PyPy team provides a way to `cross compile` at the website https://rpython.readthedocs.io/en/latest/arm.html . The translation steo is put on `Build Platform` (usually x86_64/x86 computer, with high performance) and use `Scratchbox 2` to cross compile. But, unfortunately, this tool is deprecated by Ubuntu. We need to find other ways to solve this problem.

SBox2's function is to substitute the operation of calling C compiler to the cross compiler from toolchain on the build platform, and to execute the binary under the `rootfs` with provided architecture. Using two containers of Termux Docker with clang compiler seems to be enough for this situation. But, executing clang commmand under termux:arm or termux:aarch64 will hang up as mentioned above, and I have no idea to avoid it, so we need a cross-compile toolchain under termux:x86(_64) and it seems that there is no such toolchain. NDK toolchain can only work under GLIBC rather than BIONIC LIBC, so it is also impossible to use NDK toolchain. But the containers are running under a linux system, and it shouble be able to run NDK toolchain. We can use a fake CC (`remote_cc.py` in this repo) to notify the host computer call the NDK comipler, and use some methods to synchronize the files between them. This is what this repo does.

How can we send command from the docker container to the host? Using ssh seems not to be a good choice. Docker has an RCE, which will let someone use chroot to remote any command. We can use this to solve this problem.

How can we synchronize the files between build container, target container and the host computer? We can use sshfs and docker volumn, the former lets the NDK comipler access to the headers and libraries, and the latter lets the other files synchronized.

### 1. Setup Environment

#### (1) Setup Docker over TCP

Let the docker daemon listening at tcp://127.0.0.1:2375.

```bash
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo bash -c 'cat > /etc/systemd/system/docker.service.d/tcp.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// -H tcp://127.0.0.1:2375
EOF'
sudo systemctl daemon-reload
sudo systemctl restart docker.service
curl -v http://127.0.0.1:2375/version
```

#### (2) Start Containers

If we want to compile PyPy for arm/aarch64, we need to start two containers. One is for translation, and the other is for executing binaries. Building for ARM needs i686 and arm containers, and building for aarch64 needs x86_64 and aarch64 containers.

#### (3) Setup sshfs

We should use sshfs to mount a point to the target platform container, which will let the NDK compiler access to the headers and libraries.

#### (4) Intall dependicies for container

Using apt is enough. But cffi will hang up, so we should use the fake cc.

#### (5) Notice the permission of files

In the script, I set the permission to 777 for convenience, but it is not proper. Maybe I will fix it later.

### 4. Translation

We should perform the translation under a x86_64 or i686 container.

### 5. Build

Modifying the Makefile and use `make`.

## TODO

- [ ] Upload release using Github Action
- [ ] Find a better way to solve the permission problem
- [ ] Do not use Docker, use qemu-user+chroot
- [ ] ... 

## License

All the patches in this repo is modified from the source code of PyPy. So this repo is licensed under [MIT License](http://opensource.org/licenses/MIT), same as the PyPy.

## Contribute

If you got `bugs` or `feedbacks`, please make [Issues](https://github.com/licy183/termux-pypy/issues) or send [Pull Request](https://github.com/licy183/termux-pypy/pulls), thanks for your contribution :)

## Thanks

@truboxl: My idea is inspired from his Pull Request about the build of PyPy.

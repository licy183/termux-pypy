<h1 align="center">Termux-Pypy</h1>

## 简介

本仓库提供了一种在 [Termux (Android)](https://github.com/termux/termux-app) 上编译 [PyPy](https://pypy.org/) (2/3) 的方法。

## 使用方式

### 1. 添加依赖

构建方式依赖 `Docker`、`sshfs`、`fuse3` 等。

```bash
sudo apt install docker.io sshfs fuse3
```

当然，也可以使用最新版本的 Docker，安装方式参见[官网](https://docs.docker.com/engine/install/ubuntu/)。

在安装好 Docker 之后，为了操作方便，我们可以把当前的用户加到 docker 用户组里面。

```bash
sudo usermod -aG docker user-name
```

之后要设置 Docker 上的 binfmt misc，比如使用 [qus](https://github.com/dbhi/qus)。

```bash
docker run --rm --privileged aptman/qus -s -- -p
```

### 2. (可选) 构建 Termux Docker 镜像

这一步是可选的，因为也可以使用 termux-docker 仓库中所使用的官方镜像。但是官方目前还没有提供 ARM 版本的镜像，所以如果要构建 ARM 版本的 PyPy 的话，就得自己构建 Docker 镜像。具体的逻辑可以参见仓库中的 `build-termux-docker-image.sh`。

### 3. 编译

参见 `build.sh`。

## 具体实现

### 0. 思路

编译 PyPy 可以大体分为两个部分，第一个部分是把 RPython 的部分翻译成 C 代码，第二个部分是编译 C 代码生成 PyPy 的可执行程序。如果我们简单的把整个过程放到 qemu 中做的话，花费的时间会过长，在我的电脑 (WSL2-Ubuntu20/i5-8300H/16G) 上，大概跑了有六个小时，并且，直接使用 termux-docker 运行的话，clang 编译器会莫名奇妙的卡住。当然，按照我曾经在 [评论](https://github.com/termux/termux-packages/issues/1265#issuecomment-957122896) 中提到过的方法，使用 sshfs 来做到手机上和电脑上的文件同步，然后调用手机上的 clang，可以解决这个问题，但翻译过程还是太慢了。实际上，PyPy 官方曾经给出过一种 `Cross Compile` 的方法，参见 https://rpython.readthedocs.io/en/latest/arm.html ，将翻译放到 `Build Platform` (一般是 x86_64 或者 x86 的电脑，性能较高) 来做，然后编译 C 源码的部分使用 `Cross Toolchain` 来进行。但文中给出的工具 `Scratchbox 2` ，已经不在新版本的 Ubuntu 中提供了，需要寻找别的方法。

实际上，SBox2 应该就是做了一个把调用 C 编译器的命令替换成宿主机调用 `Toolchain` 中的编译器，然后执行文件的时候，又在执行给出的 `rootfs` 中的可执行程序。采用两个 Termux Docker 容器，里面带着 clang 编译器，似乎可以进行这项工作了。但是，clang 在 arm 和 aarch64 上，会莫名其妙的卡死，目前还不知道原因。那样，就需要一个在 Termux x86 上进行跨平台翻译的 Toolchain。但是，在 Termux 上，目前并不知道有可以进行跨平台编译的 Toolchain，而 NDK 这个编译好的 Toolchain 依赖 glibc，在 Bionic libc 上也不能用。但是，我们的两个 Termux Docker 容器都是在一个电脑上运行的，这个电脑一般来说是可以跑 NDK Toolchain 的。在执行编译的时候，我们可以使用一个假的 C 编译器 (本仓库中就是 `remote_cc.py`) 来执行编译命令，同时做到三者之间的文件同步，就可以完成编译了。这也就是本仓库所做的工作。

怎么让 Docker 容器来调用主机上的命令呢？用 ssh 肯定是可以解决的，但 ssh 来调用命令的话，似乎每一次都会来交换公钥，这显然是不太合理的。Docker 存在一个 RCE，可以在暴露守护进程到公网的机器上使用 chroot 来执行指令，我们利用这个就可以来实现容器向主机的指令执行。

如何做到三者之间的数据同步呢？在本仓库中，使用的 sshfs + Docker 目录挂载的方式。使用 sshfs 来让主机上的编译器访问到要链接的库，使用 Docker 的目录挂载，实现源码上的三者同步。

### 1. 准备环境

#### (1) 设置 Docker over TCP

让 Docker 守护进程监听 tcp://127.0.0.1:2375，下面是 Ubuntu 上的设置方法，其它的 Linux 发行版类似。

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

#### (2) 启动容器

要选择正确的镜像来启动容器，如果是要编译 arm/aarch64 的话，需要启动两个容器，一个来进行翻译，一个来执行程序。编译 arm (32 位 ARM) 的话，需要 arm 和 i686 的容器，同样，编译 aarch64 (64 位 ARM)，需要 aarch64 和 x86_64 的容器。

#### (3) 设置 sshfs

我们要设置 sshfs 到编译目标平台的容器，以便主机上的 NDK 编译器可以访问到目标平台容器的头文件以及链接库。而翻译所在的平台由于一定是 x86_64 或者 i686 的，clang 是没有问题的。

#### (4) 安装编译所需要的库

这个直接使用 apt 安装就行了。需要注意的是，cffi 需要 clang 来编译，可能会卡死，因此得使用 remote_gcc。

#### (5) 注意文件权限和所有者

在 Github Action 的操作中，我为了省事，直接改成 777 了，有时间的话我会改掉的。

### 4. 翻译

正如上面所说的，我们把翻译放到一个 x86_64 或者 i686 的容器中来做，修改 PyPy 中的部分源码就可以做到。

### 5. 编译

编译的时候，我们在主机上把 Makefile 改了应该就能编译。

## TODO

- [ ] 使用 Github Action 上传 Release
- [ ] 修改 uid/gid，而不是直接设置 777
- [ ] 不使用 Docker 而使用 qemu-user+chroot 来完成翻译过程 (理论上可行)
- [ ] ... (还没想到，想到再加 orz...)

## License

本代码中的所有 Patch 来源于 PyPy 源码的修改，因而采用和 PyPy 相同的 [MIT License](http://opensource.org/licenses/MIT) 开源。

## Contribute
 
如果有 `Bug反馈` 或 `功能建议`，请创建 [Issue](https://github.com/licy183/termux-pypy/issues) 或提交 [Pull Request](https://github.com/licy183/termux-pypy/pulls)，感谢您的参与和贡献。

## 鸣谢

@truboxl: 使用 Termux Docker 来运行 Termux 环境下的上二进制文件这一思路，来源与他关于 PyPy 编译的 Pull Request。

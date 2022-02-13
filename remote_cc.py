#!/usr/bin/env python2
import logging as log
import os
import sys

import docker

host_wrapper = docker.from_env(
    environment={'DOCKER_HOST': 'http://127.0.0.1:2375'}).containers.get("ndk-wrapper")

TERMUX_PREFIX = '/data/data/com.termux/files/usr'

ANDROID_NDK_HOME = os.getenv('ANDROID_NDK_HOME')
if ANDROID_NDK_HOME is None:
    log.error('ANDROID_NDK_HOME: Provide a path to the android NDK home in env variable ANDROID_NDK_HOME')
    assert 0

TARGET_ARCH = os.getenv('TARGET_ARCH')
if TARGET_ARCH is None:
    log.error('TARGET_ARCH: Provide the target arch in env variable TARGET_ARCH')
    assert 0

CROSS_COMPILER_PATH = ANDROID_NDK_HOME + "/toolchains/llvm/prebuilt/linux-x86_64/bin/"

CFLAGS = os.environ.get('CFLAGS', '-fPIC').split()
CXXFLAGS = os.environ.get('CXXFLAGS', '').split()
LDFLAGS = os.environ.get('LDFLAGS', '').split()

CFLAGS += ["-fstack-protector-strong", "-fopenmp",
           "-I" + TERMUX_PREFIX + "/include", 
           "-DBIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD"]

LDFLAGS += ["-L" + TERMUX_PREFIX + "/lib", "-fopenmp",
            "-Wl,--enable-new-dtags", "-Wl,--as-needed", 
            "-Wl,-z,relro,-z,now", "-static-openmp", 
            "-Wl,-rpath=" + TERMUX_PREFIX + "/lib"]

if TARGET_ARCH == "x86_64":
    CROSS_COMPILER = CROSS_COMPILER_PATH + "x86_64-linux-android24-clang"
elif TARGET_ARCH == "i686":
    CROSS_COMPILER = CROSS_COMPILER_PATH + "i686-linux-android24-clang"
    CFLAGS = ["-march=i686", "-msse3", "-mstackrealign", "-mfpmath=sse"] + CFLAGS
elif TARGET_ARCH == "aarch64":
    CROSS_COMPILER = CROSS_COMPILER_PATH + "aarch64-linux-android24-clang"
elif TARGET_ARCH == "arm":
    CROSS_COMPILER = CROSS_COMPILER_PATH + "armv7a-linux-androideabi24-clang"
    CFLAGS = ["-march=armv7-a", "-mfpu=neon", "-mfloat-abi=softfp", "-mthumb"] + CFLAGS
    LDFLAGS = ["-march=armv7-a"] + LDFLAGS
else:
    log.error("TARGET_ARCH: Must be one of 'x86_64', 'i686', 'aarch64', 'arm'.")
    assert 0

CXXFLAGS += CFLAGS

def main(argv):
    cwd = os.getcwd()
    argv = argv[1:]
    argv = [arg if arg[0] in ("-", '/') else (cwd + "/" + arg) for arg in argv]
    # TODO: Do not append flags in the command line. Use env vars.
    argv = [CROSS_COMPILER] + CXXFLAGS + LDFLAGS + argv
    sys.stdout.write("Host: " + " ".join(argv))
    sys.stdout.flush()
    args = ["chroot", "/rootfs"] + argv
    returncode, (stdout, stderr) = host_wrapper.exec_run(args, demux=True)
    stdout = "" if stdout == None else stdout
    stderr = "" if stderr == None else stderr
    sys.stdout.write(stdout)
    sys.stdout.flush()
    sys.stderr.write(stderr)
    sys.stderr.flush()
    exit(returncode)


if __name__ == '__main__':
    main(sys.argv)

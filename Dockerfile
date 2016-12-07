# Copyright 2016 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This file creates a standard build environment for building cross
# platform go binary for the architecture kubernetes cares about.

FROM golang:1.6.3

ENV GOARM 6
ENV KUBE_DYNAMIC_CROSSPLATFORMS \
  armel \
  arm64 \
  ppc64el

ENV KUBE_CROSSPLATFORMS \
  linux/386 \
  linux/arm linux/arm64 \
  linux/ppc64le \
  darwin/amd64 darwin/386 \
  windows/amd64 windows/386

# Pre-compile the standard go library when cross-compiling. This is much easier now when we have go1.5+
RUN for platform in ${KUBE_CROSSPLATFORMS}; do GOOS=${platform%/*} GOARCH=${platform##*/} go install std; done

# Install g++, then download and install protoc for generating protobuf output
RUN apt-get update \
  && apt-get install -y g++ rsync apt-utils file patch \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/local/src/protobuf \
  && cd /usr/local/src/protobuf \
  && curl -sSL https://github.com/google/protobuf/releases/download/v3.0.0-beta-2/protobuf-cpp-3.0.0-beta-2.tar.gz | tar -xzv \
  && cd protobuf-3.0.0-beta-2 \
  && ./configure \
  && make install \
  && ldconfig \
  && cd .. \
  && rm -rf protobuf-3.0.0-beta-2 \
  && protoc --version

# Use dynamic cgo linking for architectures other than amd64 for the server platforms
# More info here: https://wiki.debian.org/CrossToolchains
RUN echo "deb http://emdebian.org/tools/debian/ jessie main" > /etc/apt/sources.list.d/cgocrosscompiling.list \
  && curl -s http://emdebian.org/tools/debian/emdebian-toolchain-archive.key | apt-key add - \
  && for platform in ${KUBE_DYNAMIC_CROSSPLATFORMS}; do dpkg --add-architecture ${platform}; done \
  && apt-get update \
  && apt-get install -y build-essential \
  && for platform in ${KUBE_DYNAMIC_CROSSPLATFORMS}; do apt-get install -y crossbuild-essential-${platform}; done \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# work around 64MB tmpfs size in Docker 1.6
ENV TMPDIR /tmp.k8s

# Get the code coverage tool, godep, and go-bindata
RUN mkdir $TMPDIR \
  && chmod a+rwx $TMPDIR \
  && chmod o+t $TMPDIR \
  && go get golang.org/x/tools/cmd/cover \
            golang.org/x/tools/cmd/goimports \
            github.com/tools/godep \
            github.com/jteeuwen/go-bindata/go-bindata

# Download and symlink etcd. We need this for our integration tests.
RUN export ETCD_VERSION=v3.0.13; \
  mkdir -p /usr/local/src/etcd \
  && cd /usr/local/src/etcd \
  && curl -fsSL https://github.com/coreos/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz | tar -xz \
  && ln -s ../src/etcd/etcd-${ETCD_VERSION}-linux-amd64/etcd /usr/local/bin/

# TODO: Remove the patched GOROOT when we have an official golang that has a working arm and ppc64le linker
ENV K8S_PATCHED_GOLANG_VERSION=1.7.1 \
    K8S_PATCHED_GOROOT=/usr/local/go_k8s_patched
RUN mkdir -p ${K8S_PATCHED_GOROOT} \
  && curl -sSL https://github.com/golang/go/archive/go${K8S_PATCHED_GOLANG_VERSION}.tar.gz | tar -xz -C ${K8S_PATCHED_GOROOT} --strip-components=1

# We need a patched go1.7.1 for linux/arm (https://github.com/kubernetes/kubernetes/issues/29904)
# We need go1.7.1 for all darwin builds (https://github.com/kubernetes/kubernetes/issues/32999)
COPY golang-patches/CL28857-go1.7.1-luxas.patch ${K8S_PATCHED_GOROOT}/
RUN cd ${K8S_PATCHED_GOROOT} \
  && patch -p1 < CL28857-go1.7.1-luxas.patch \
  && cd src \
  && GOROOT_FINAL=${K8S_PATCHED_GOROOT} GOROOT_BOOTSTRAP=/usr/local/go ./make.bash \
  && for platform in linux/arm darwin/386 darwin/amd64; do GOOS=${platform%/*} GOARCH=${platform##*/} GOROOT=${K8S_PATCHED_GOROOT} go install std; done

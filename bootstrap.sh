#!/bin/bash
# Copyright 2007-2015 Zuse Institute Berlin
# 
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
# 
#        http://www.apache.org/licenses/LICENSE-2.0
# 
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

## update version ##

VERSION=`cat VERSION`
VERSION_NOPLUS=`echo "${VERSION}" | tr + _`
if [[ "$VERSION" == *git* ]]; then
  ## maven snapshot versions must have revision incremented by 1 so that 
  ## maven sees them as a newer version than the release
  VERSION_NOGIT=${VERSION%+git*}
  MAJOR_MINOR=${VERSION_NOGIT%.*}
  REVISION=${VERSION_NOGIT##*.}
  ((REVISION++))
  VERSION_MAVEN="$MAJOR_MINOR.$REVISION-SNAPSHOT"
else
  VERSION_MAVEN=$VERSION
fi


echo "Setting Scalaris version to ${VERSION}..."
sed -e "s/-define(SCALARIS_VERSION, \".*\")\\./-define(SCALARIS_VERSION, \"${VERSION}\")./g" \
    -i include/scalaris.hrl
sed -e "s/AC_INIT(scalaris, .*, scalaris@googlegroups.com)/AC_INIT(scalaris, ${VERSION}, scalaris@googlegroups.com)/g" \
    -i configure.ac
sed -e "s/public static final String version = \".*\";/public static final String version = \"${VERSION}\";/g" \
    -i contrib/wikipedia/src/de/zib/scalaris/examples/wikipedia/bliki/WikiServlet.java
sed -e "s/version='.*',/version='${VERSION}',/g" \
    -i python-api/setup.py
sed -e "s/SCALARIS_VERSION=\".*\"/SCALARIS_VERSION=\"${VERSION}\"/g" \
    -i contrib/packages/*/checkout.sh
sed -e "s/%define pkg_version .*/%define pkg_version ${VERSION}/g" \
    -i contrib/packages/*/*.spec
sed -e "s/Version: .*-.*/Version: ${VERSION}-1/g" \
    -i contrib/packages/*/*.dsc
sed -e "0,/(.*-.*)/s//(${VERSION}-1)/" \
    -i contrib/packages/*/debian.changelog
sed -e "0,/<version>.*<\/version>/s//<version>${VERSION_MAVEN}<\/version>/" \
    -i java-api/pom.xml contrib/datanucleus/scalaris-datanucleus-store/pom.xml
sed -e "s/module scalaris .*;/module scalaris ${VERSION_NOPLUS};/g" \
    -i contrib/systemd/scalaris.te
if [[ "$VERSION" == *git* ]]; then
  RELEASE="unstable"
else
  RELEASE="stable"
fi
sed -e "0,/u*n*stable;/s//${RELEASE};/" \
    -i contrib/packages/*/debian.changelog
echo "done"
sed -e "s/pkgver=.*/pkgver=${VERSION}/g" \
    -i contrib/packages/*/PKGBUILD

##########

echo "Creating configure script"
aclocal -Wobsolete -I m4
autoconf -Wobsolete
echo "done"

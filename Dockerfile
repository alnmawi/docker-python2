ARG PYTHON_VERSION=2.7.18
# https://www.python.org/dev/peps/pep-0373/#release-manager-and-crew
ARG PYTHON_GPG_KEY=C01E1CAD5EA2C4F0B8E3571504C367C218ADD4FF

ARG PYTHON_PIP_VERSION=20.3.3
# https://github.com/pypa/get-pip
ARG PYTHON_GET_PIP_URL=https://raw.githubusercontent.com/pypa/get-pip/20.3.3/get-pip.py
ARG PYTHON_GET_PIP_SHA256=6a0b13826862f33c13b614a921d36253bfa1ae779c5fbf569876f3585057e9d2


FROM alpine:3.15.4


ARG PYTHON_VERSION
ARG PYTHON_GPG_KEY

# http://bugs.python.org/issue19846
ENV LANG=C.UTF-8
# https://github.com/docker-library/python/issues/147
ENV PYTHONIOENCODING=UTF-8

RUN set -ex \
\
# create build directory
&&  _builddir=$(mktemp -d) \
&&  _stamp="$_builddir/stamp" \
&&  touch "$_stamp" && sleep 1 \
&&  cd "$_builddir" \
\
# compile flags, optimize for small size
&&  export CFLAGS="-Os -fomit-frame-pointer" \
&&  export CXXFLAGS="$CFLAGS" \
&&  export CPPFLAGS="$CFLAGS" \
&&  export LDFLAGS="-Wl,--as-needed" \
&&  export JOBS=$(nproc) \
\
# make sure ca-certificates-bundle package is installed
&&  apk add --no-cache ca-certificates-bundle \
\
# fetch and check integrity of sources
# - integrity check dependencies install
&&  apk add --no-cache --virtual .fetch-deps gnupg \
&&  export GNUPGHOME="$_builddir/.gnupg" \
# - Python
&&  wget -qO python.tar.xz "https://www.python.org/ftp/python/${PYTHON_VERSION%%[a-z]*}/Python-$PYTHON_VERSION.tar.xz" \
&&  wget -qO python.tar.xz.asc "https://www.python.org/ftp/python/${PYTHON_VERSION%%[a-z]*}/Python-$PYTHON_VERSION.tar.xz.asc" \
&&  gpg --batch --keyserver ha.pool.sks-keyservers.net --recv-keys "$PYTHON_GPG_KEY" \
&&  gpg --batch --verify python.tar.xz.asc python.tar.xz \
# - integrity check cleanup
&&  { command -v gpgconf >/dev/null && gpgconf --kill all || true; } \
&&  rm -rf "$GNUPGHOME" python.tar.xz.asc \
&&  unset -v GNUPGHOME \
\
# unpack sources
&&  mkdir -p "$_builddir/python" \
&&  tar -xJC "$_builddir/python" --strip-components=1 -f python.tar.xz \
&&  rm python.tar.xz \
\
# install build dependencies
# - python modules not being built:
#   - obsolete: _bsddb bsddb185 dl imageop sunaudiodev
#   - other: _tkinter nis
&&  apk add --no-cache --virtual .build-deps \
        gcc \
        make \
        bzip2-dev \
        expat-dev \
        gdbm-dev \
        libc-dev \
        libffi-dev \
#        libnsl-dev \
        ncurses-dev \
        openssl-dev \
        readline-dev \
        sqlite-dev \
#        tk-dev \
        zlib-dev \
\
# remove fetch dependencies _after_ adding build dependencies in case there's overlap
&&  apk del --no-cache .fetch-deps \
# - pinentry link is left dangling after fetch dependencies removal
&&  rm -f /usr/bin/pinentry \
\
# build Python
&&  cd "$_builddir/python" \
&&  OPT="-fwrapv -Os -Wall -Wstrict-prototypes" \
    ./configure \
        --enable-option-checking=fatal \
        --enable-shared \
        --enable-optimizations \
        --enable-ipv6 \
        --enable-unicode=ucs4 \
        --with-system-expat \
        --with-system-ffi \
        --with-signal-module \
        --with-threads \
&&  make -j$JOBS \
# - set thread stack size to 1MB so we don't segfault before we hit sys.getrecursionlimit()
#   https://github.com/alpinelinux/aports/commit/2026e1259422d4e0cf92391ca2d3844356c649d0
        EXTRA_CFLAGS="-DTHREAD_STACK_SIZE=0x100000" \
# - setting PROFILE_TASK makes "--enable-optimizations" reasonable
#   https://bugs.python.org/issue36044
#   https://github.com/docker-library/python/issues/160#issuecomment-509426916
        PROFILE_TASK='-m test.regrtest --pgo \
            test_array \
            test_base64 \
            test_binascii \
            test_binhex \
            test_binop \
            test_bytes \
            test_c_locale_coercion \
            test_class \
            test_cmath \
            test_codecs \
            test_compile \
            test_complex \
            test_csv \
            test_decimal \
            test_dict \
            test_float \
            test_fstring \
            test_hashlib \
            test_io \
            test_iter \
            test_json \
            test_long \
            test_math \
            test_memoryview \
            test_pickle \
            test_re \
            test_set \
            test_slice \
            test_struct \
            test_threading \
            test_time \
            test_traceback \
            test_unicode \
        ' \
&&  make install \
&&  cd - \
\
# remove extra files
# - python modules
&&  find /usr/local/lib/python2* -depth \
        -type d -newer "$_stamp" -a \
        \( \
            -name test -o \
            -name tests -o \
            -name idle_test -o \
            -name ensurepip -o \
            -name idlelib -o \
            -name lib-tk -o \
        \) \
        -exec rm -rf '{}' + \
# - python cache files
&&  find /usr/local/lib/python2* -depth \
        -type f -newer "$_stamp" -a \
        \( \
            -name '*.pyc' -o \
            -name '*.pyo' \
        \) \
        -exec rm -rf '{}' + \
# - scripts
&&  rm -f /usr/local/bin/2to3 /usr/local/bin/idle /usr/local/bin/smtpd.py \
# - manuals
&&  rm -rf /usr/local/share/man \
\
# strip binaries
&&  find /usr/local -type f -newer "$_stamp" -exec scanelf --nobanner --osabi --etype "ET_DYN,ET_EXEC" "{}" + \
|   while read _type _osabi _file; do \
        if [ -e "$_file" -a "$_osabi" != "STANDALONE" ]; then \
            strip "$_file"; \
        fi; \
    done \
\
# scan for runtime dependencies
&&  find /usr/local -type f -newer "$_stamp" -exec scanelf --nobanner --needed --format "%n#p" "{}" + \
|   tr "," "\n" \
|   sort -u \
|   while read _file; do \
        [ -e "/usr/local/lib/$_file" ] || echo "so:$_file"; \
    done \
|   xargs -rt apk add --no-cache --virtual .python-rundeps \
\
# remove build dependencies
&&  apk del --no-cache .build-deps \
\
# remove build directory
&&  cd /tmp \
&&  rm -rf "$_builddir"


ARG PYTHON_PIP_VERSION
ARG PYTHON_GET_PIP_URL
ARG PYTHON_GET_PIP_SHA256

RUN set -ex \
\
# create build directory
&&  _builddir=$(mktemp -d) \
&&  _stamp="$_builddir/stamp" \
&&  touch "$_stamp" \
&&  cd "$_builddir" \
\
# get pip install script
&&  wget -qO get-pip.py "$PYTHON_GET_PIP_URL" \
&&  echo "$PYTHON_GET_PIP_SHA256 *get-pip.py" | sha256sum -c - \
\
# install pip
&&  python2 get-pip.py \
        --disable-pip-version-check \
        --no-cache-dir \
        "pip==$PYTHON_PIP_VERSION" \
&&  rm -f get-pip.py \
\
# remove extra files
# - python cache files
&&  find /usr/local/lib/python2* -depth \
        -type f -newer "$_stamp" -a \
        \( \
            -name '*.pyc' -o \
            -name '*.pyo' \
        \) \
        -exec rm -rf '{}' + \
\
# remove build directory
&&  cd /tmp \
&&  rm -rf "$_builddir"


CMD ["python2"]

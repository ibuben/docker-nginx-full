#!/bin/bash -e

BLUE='\E[1;34m'
CYAN='\E[1;36m'
YELLOW='\E[1;33m'
GREEN='\E[1;32m'
RESET='\E[0m'

echo -e "${BLUE}❯ ${CYAN}Building OpenResty ${YELLOW}${OPENRESTY_VERSION} with nginx_http_geoip2 module...${RESET}"

cd /tmp

# The official releases:
# wget "https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz" -O "openresty-${OPENRESTY_VERSION}.tar.gz"

# The github tagged releases:
wget "https://github.com/openresty/openresty/archive/refs/tags/v${OPENRESTY_VERSION}.tar.gz" -O "openresty-${OPENRESTY_VERSION}.tar.gz"

tar -xzf "openresty-${OPENRESTY_VERSION}.tar.gz"
mv "/tmp/openresty-${OPENRESTY_VERSION}" /tmp/openresty
git clone 'https://github.com/leev/ngx_http_geoip2_module.git'
mv /tmp/ngx_http_geoip2_module /tmp/openresty/ngx_http_geoip2_module
cd /tmp/openresty

BUNDLED_NGINX_VERSION="$(sed -n 's/^main_ver=//p' util/ver)"

if [ -n "${NGINX_VERSION:-}" ] && [ "$NGINX_VERSION" != "$BUNDLED_NGINX_VERSION" ]; then
	echo -e "${BLUE}❯ ${CYAN}Rebasing OpenResty nginx patches from ${YELLOW}${BUNDLED_NGINX_VERSION}${CYAN} to ${YELLOW}${NGINX_VERSION}...${RESET}"

	ver_num() {
		echo "$1" | awk -F. '{ printf "%d%03d%03d", $1, $2, $3 }'
	}

	OLD_RE="${BUNDLED_NGINX_VERSION//./\\.}"
	OLD_NUM="$(ver_num "$BUNDLED_NGINX_VERSION")"
	NEW_NUM="$(ver_num "$NGINX_VERSION")"

	# OpenResty's patches embed the nginx version in file names and in context lines (e.g. nginx.h),
	# any hunk that no longer applies makes util/mirror-tarballs fail the build.
	mv "patches/nginx/${BUNDLED_NGINX_VERSION}" "patches/nginx/${NGINX_VERSION}"
	for f in "patches/nginx/${NGINX_VERSION}"/*.patch; do
		sed -i "s/${OLD_RE}/${NGINX_VERSION}/g; s/${OLD_NUM}/${NEW_NUM}/g" "$f"
		mv "$f" "${f//nginx-${BUNDLED_NGINX_VERSION}-/nginx-${NGINX_VERSION}-}"
	done
	sed -i "s/^main_ver=.*/main_ver=${NGINX_VERSION}/" util/ver

	# openresty.org only mirrors the nginx versions it ships. Its mirror is the GitHub tag archive
	# with auto/configure moved to the top level, util/get-tarball picks it up from work/.
	mkdir -p work /tmp/nginx-src
	wget "https://github.com/nginx/nginx/archive/refs/tags/release-${NGINX_VERSION}.tar.gz" -O /tmp/nginx-src/nginx.tar.gz
	tar -xzf /tmp/nginx-src/nginx.tar.gz -C /tmp/nginx-src
	mv "/tmp/nginx-src/nginx-release-${NGINX_VERSION}" "/tmp/nginx-src/nginx-${NGINX_VERSION}"
	mv "/tmp/nginx-src/nginx-${NGINX_VERSION}/auto/configure" "/tmp/nginx-src/nginx-${NGINX_VERSION}/configure"
	tar -czf "work/nginx-${NGINX_VERSION}.tar.gz" -C /tmp/nginx-src "nginx-${NGINX_VERSION}"
	rm -rf /tmp/nginx-src
fi

make

# install-openresty.sh expects the bundle under the OpenResty release version
BUNDLE_VERSION="$(./util/ver)"
if [ "$BUNDLE_VERSION" != "$OPENRESTY_VERSION" ]; then
	mv "/tmp/openresty/openresty-${BUNDLE_VERSION}" "/tmp/openresty/openresty-${OPENRESTY_VERSION}"
fi

cd "/tmp/openresty/openresty-${OPENRESTY_VERSION}"

./configure \
	--prefix=/etc/nginx \
	--sbin-path=/usr/sbin/nginx \
	--modules-path=/usr/lib/nginx/modules \
	--conf-path=/etc/nginx/nginx.conf \
	--error-log-path=/var/log/nginx/error.log \
	--http-log-path=/var/log/nginx/access.log \
	--pid-path=/var/run/nginx.pid \
	--lock-path=/var/run/nginx.lock \
	--http-client-body-temp-path=/var/cache/nginx/client_temp \
	--http-proxy-temp-path=/var/cache/nginx/proxy_temp \
	--http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
	--http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
	--http-scgi-temp-path=/var/cache/nginx/scgi_temp \
	--user=nginx \
	--group=nginx \
	--with-compat \
	--with-threads \
	--with-http_addition_module \
	--with-http_auth_request_module \
	--with-http_dav_module \
	--with-http_flv_module \
	--with-http_gunzip_module \
	--with-http_gzip_static_module \
	--with-http_mp4_module \
	--with-http_random_index_module \
	--with-http_realip_module \
	--with-http_secure_link_module \
	--with-http_slice_module \
	--with-http_ssl_module \
	--with-http_stub_status_module \
	--with-http_sub_module \
	--with-http_v2_module \
	--with-mail \
	--with-mail_ssl_module \
	--with-stream \
	--with-stream_realip_module \
	--with-stream_ssl_module \
	--with-stream_ssl_preread_module \
	--with-http_v3_module \
	--add-dynamic-module=/tmp/openresty/ngx_http_geoip2_module

make -j"$(nproc)"

echo -e "${BLUE}❯ ${GREEN}OpenResty build completed${RESET}"

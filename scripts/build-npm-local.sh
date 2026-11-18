#!/bin/bash -e

# Builds nginx-full (OpenResty with NGINX_VERSION) and Nginx Proxy Manager on top of it,
# into the local Docker daemon only. Intended for a clean Debian 13 host, run as root.
#
# Overridable: NPM_VERSION, NGINX_VERSION, FORK_REPO, FORK_BRANCH, WORK_DIR, IMAGE_PREFIX

NPM_VERSION="${NPM_VERSION:-2.17.0}"
NGINX_VERSION="${NGINX_VERSION:-1.31.9}"
FORK_REPO="${FORK_REPO:-https://github.com/ibuben/docker-nginx-full.git}"
FORK_BRANCH="${FORK_BRANCH:-cursor/nginx-1-31-9-9707}"
WORK_DIR="${WORK_DIR:-/opt/npm-build}"
IMAGE_PREFIX="${IMAGE_PREFIX:-local}"

BLUE='\E[1;34m'
CYAN='\E[1;36m'
YELLOW='\E[1;33m'
GREEN='\E[1;32m'
RED='\E[1;31m'
RESET='\E[0m'

step() {
	echo -e "${BLUE}❯ ${CYAN}$*${RESET}"
}

if [ "$(id -u)" -ne 0 ]; then
	echo -e "${RED}Run as root${RESET}"
	exit 1
fi

ARCH="$(dpkg --print-architecture)"
PLATFORM="linux/${ARCH}"
BASE_IMAGE="${IMAGE_PREFIX}/nginx-full"
NPM_IMAGE="${IMAGE_PREFIX}/nginx-proxy-manager:${NPM_VERSION}-nginx${NGINX_VERSION}"

step "Installing Docker"
if ! command -v docker >/dev/null 2>&1 || ! docker buildx version >/dev/null 2>&1; then
	apt-get update
	apt-get install -y ca-certificates curl git
	install -m 0755 -d /etc/apt/keyrings
	curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc
	# shellcheck disable=SC1091
	CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
	echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable" \
		>/etc/apt/sources.list.d/docker.list
	apt-get update
	apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	systemctl enable --now docker || true
fi
command -v git >/dev/null 2>&1 || { apt-get update && apt-get install -y git; }

if ! docker run --rm hello-world >/dev/null 2>&1; then
	echo -e "${RED}Docker cannot start containers. In an LXC container enable nesting (Proxmox: Options > Features > nesting, keyctl) and reboot it.${RESET}"
	exit 1
fi

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

step "Building ${YELLOW}${BASE_IMAGE}:certbot-node${CYAN} with nginx ${YELLOW}${NGINX_VERSION}${CYAN} for ${YELLOW}${PLATFORM}"
rm -rf docker-nginx-full
git clone --depth 1 --branch "$FORK_BRANCH" "$FORK_REPO" docker-nginx-full
(
	cd docker-nginx-full
	DOCKER_IMAGE="$BASE_IMAGE" NGINX_VERSION="$NGINX_VERSION" BUILDX_NAME=npmlocal \
		./scripts/bake.sh certbot-node --set "*.platform=${PLATFORM}" --load
)
# bake.sh switches buildx to its own builder, which cannot see images in the local daemon
docker buildx use default

ACTUAL="$(docker run --rm "${BASE_IMAGE}:certbot-node" nginx -v 2>&1)"
echo "$ACTUAL"
if ! echo "$ACTUAL" | grep -q "/${NGINX_VERSION}\."; then
	echo -e "${RED}Base image does not report nginx ${NGINX_VERSION}${RESET}"
	exit 1
fi

step "Building Nginx Proxy Manager ${YELLOW}v${NPM_VERSION}"
rm -rf nginx-proxy-manager
git clone --depth 1 --branch "v${NPM_VERSION}" https://github.com/NginxProxyManager/nginx-proxy-manager.git
(
	cd nginx-proxy-manager
	# The release tag carries a placeholder version, official CI stamps the real one in the same way
	sed -i -E "0,/\"version\":/s/(\"version\": *)\"[^\"]*\"/\1\"${NPM_VERSION}\"/" frontend/package.json backend/package.json
	grep -h '"version"' frontend/package.json backend/package.json

	docker run --rm \
		-e CI=true \
		-e NODE_OPTIONS=--openssl-legacy-provider \
		-v "$(pwd)/frontend:/app/frontend" \
		-w /app/frontend "${BASE_IMAGE}:certbot-node" \
		sh -c "yarn install && yarn locale-compile && yarn build"

	docker build \
		-f docker/Dockerfile \
		--build-arg BASE_IMAGE="${BASE_IMAGE}:certbot-node" \
		--build-arg BUILD_VERSION="$NPM_VERSION" \
		--build-arg BUILD_COMMIT="$(git rev-parse --short HEAD)" \
		--build-arg BUILD_DATE="$(date '+%Y-%m-%d %T %Z')" \
		-t "$NPM_IMAGE" \
		.
)

step "Checking the image"
docker run --rm --entrypoint nginx "$NPM_IMAGE" -v

echo -e "${BLUE}❯ ${GREEN}Done: ${YELLOW}${NPM_IMAGE}${RESET}"
echo "Export it for other servers with:"
echo "  docker save ${NPM_IMAGE} | gzip > npm-${NPM_VERSION}-nginx${NGINX_VERSION}.tar.gz"

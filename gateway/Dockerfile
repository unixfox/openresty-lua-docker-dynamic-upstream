FROM alpine:3.20 AS builder

RUN apk add --no-cache \
    build-base perl curl git linux-headers \
    pcre-dev openssl-dev zlib-dev

WORKDIR /build

ARG OPENRESTY_VERSION=1.27.1.2
RUN curl -sL https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz | tar xz

# Dependencies: ngx_dynamic_upstream (C module) + ngx_dynamic_upstream_lua (Lua bindings).
RUN git clone --depth 1 https://github.com/ZigzagAK/ngx_dynamic_upstream.git
RUN git clone --depth 1 https://github.com/ZigzagAK/ngx_dynamic_upstream_lua.git

WORKDIR /build/openresty-${OPENRESTY_VERSION}

# Two-step: configure first to unpack bundled modules, then patch include path for stream-lua.
RUN ./configure \
        --with-stream \
        --add-module=../ngx_dynamic_upstream \
        --add-module=../ngx_dynamic_upstream_lua

RUN STREAM_LUA_SRC=$(find /build -maxdepth 3 -name 'ngx_stream_lua-*' -type d | head -1)/src \
    && sed -i "s|-I objs|-I ${STREAM_LUA_SRC} -I objs|" build/nginx-*/objs/Makefile \
    && make -j"$(nproc)" \
    && make install

RUN /usr/local/openresty/bin/opm get ledgetech/lua-resty-http

# ---- Runtime ----
FROM alpine:3.20

RUN apk add --no-cache pcre openssl zlib libgcc libstdc++

COPY --from=builder /usr/local/openresty /usr/local/openresty
ENV PATH="/usr/local/openresty/bin:/usr/local/openresty/nginx/sbin:${PATH}"

COPY gateway/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY gateway/lua/ /etc/nginx/lua/

EXPOSE 80
STOPSIGNAL SIGQUIT
CMD ["openresty", "-g", "daemon off;"]

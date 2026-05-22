FROM ubuntu:24.04 AS base
USER root

ENV WEB_ROOT=/web_root
ENV ARCHES_ROOT=${WEB_ROOT}/arches
ENV WHEELS=/wheels
ENV PYTHONUNBUFFERED=1
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        software-properties-common \
        make

# Register third-party apt repos (Node.js, PostgreSQL) and refresh the
# package lists. Both downstream stages inherit the populated lists so
# they can `apt-get install` directly without running update again.
RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -sc)-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update

FROM base AS wheelbuilder

WORKDIR ${WHEELS}

RUN set -ex \
    && apt-get install -y --no-install-recommends \
        build-essential \
        libxml2-dev \
        libproj-dev \
        libjson-c-dev \
        xsltproc \
        docbook-xsl \
        docbook-mathml \
        libgdal-dev \
        libpq-dev \
        python3.12 \
        python3.12-dev \
        python3.12-venv \
        python3-pip \
        libldap2-dev \
        libsasl2-dev \
        ldap-utils \
        dos2unix

RUN python3.12 -m pip install --break-system-packages --no-cache-dir wheel \
    && python3.12 -m pip wheel --no-cache-dir -w ${WHEELS} gunicorn django-auth-ldap

COPY docker/entrypoint.sh ${WHEELS}/entrypoint.sh
RUN chmod -R 700 ${WHEELS} \
    && dos2unix ${WHEELS}/*.sh

FROM base

RUN mkdir ${WEB_ROOT}

COPY --from=wheelbuilder ${WHEELS} /wheels

RUN apt-get install -y --no-install-recommends \
        media-types \
        mailcap \
        libgdal-dev \
        postgresql-client-16 \
        python3.12 \
        python3.12-venv \
        nodejs

# Build deps for source-only Python packages (e.g. psycopg2). Kept as a
# separate layer to preserve cache during iteration.
RUN apt-get install -y --no-install-recommends \
        build-essential \
        libpq-dev \
        python3.12-dev

WORKDIR ${WEB_ROOT}

RUN mv ${WHEELS}/entrypoint.sh entrypoint.sh

RUN python3.12 -m venv ENV \
    && . ENV/bin/activate \
    && pip install --no-cache-dir --upgrade 'pip>=25.1' \
    && pip install --no-cache-dir requests \
    && pip install --no-cache-dir -f ${WHEELS} django-auth-ldap gunicorn \
    && rm -rf ${WHEELS} \
    && rm -rf /root/.cache/pip/*

COPY . ${ARCHES_ROOT}

WORKDIR ${ARCHES_ROOT}

RUN . ../ENV/bin/activate \
    && pip install -e . --group dev

RUN npm install --prefix ${ARCHES_ROOT}

COPY docker/gunicorn_config.py ${ARCHES_ROOT}/gunicorn_config.py
COPY docker/settings_local.py ${ARCHES_ROOT}/arches/settings_local.py

RUN rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["../entrypoint.sh"]
CMD ["run_arches"]

EXPOSE 8000

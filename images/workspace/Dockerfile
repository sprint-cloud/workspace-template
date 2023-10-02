FROM ubuntu:jammy
LABEL org.opencontainers.image.source https://github.com/sprint-cloud/workspace-template

RUN 

RUN apt-get update \
    && apt-get install -y \
    zsh \
    git \
    curl \
    postgresql-client \
    redis-tools \
    python3 \
    python3-venv \
    && apt-get clean

# Create user

RUN adduser --shell /bin/zsh \
    --home /userdata/home \
    --no-create-home \
    --disabled-password \
    --gecos '' \ 
    sprinter
RUN mkdir /userdata \
    && chown -R sprinter:sprinter /userdata

# Bootstrap Home
RUN mkdir /bootstrap
RUN git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git /oh-my-zsh
COPY bootstrap /bootstrap
RUN chown -R sprinter:sprinter /bootstrap







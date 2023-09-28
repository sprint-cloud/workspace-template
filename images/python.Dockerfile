FROM ubuntu:jammy
ARG tekton_version=0.30.0
ARG knative_version=1.9.2
ARG argocd_version=2.6.7

USER root
RUN apt-get update 
RUN apt-get install -y git curl zsh python3 python3-venv postgresql-client graphviz

WORKDIR /tmp/build
# Install Kubectl
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"\
    && curl -LO "https://dl.k8s.io/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256"
RUN echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
# Install Tekton client
RUN curl -LO https://github.com/tektoncd/cli/releases/download/v${tekton_version}/tkn_${tekton_version}_Linux_x86_64.tar.gz\
    && curl -L https://github.com/tektoncd/cli/releases/download/v${tekton_version}/checksums.txt -o tkn.sha256
RUN sha256sum --ignore-missing -c tkn.sha256 && tar xvzf tkn_${tekton_version}_Linux_x86_64.tar.gz -C /usr/local/bin/ tkn
# Install Knative client
RUN curl -LO https://github.com/knative/client/releases/download/knative-v${knative_version}/kn-linux-amd64\
    && curl -L https://github.com/knative/client/releases/download/knative-v${knative_version}/checksums.txt -o kn.sha256
RUN sha256sum --ignore-missing -c kn.sha256 && install -o root -g root -m 0755 kn-linux-amd64 /usr/local/bin/kn
# Install Argocd client
RUN curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/download/v${argocd_version}/argocd-linux-amd64\
    && curl -LO https://github.com/argoproj/argo-cd/releases/download/v${argocd_version}/argocd-${argocd_version}-checksums.txt
RUN sha256sum --ignore-missing -c argocd-${argocd_version}-checksums.txt && install -o root -g root -m 0755 argocd-linux-amd64 /usr/local/bin/argocd
# Install Helm
RUN curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && chmod 700 get_helm.sh
RUN ./get_helm.sh

# Install poetry
RUN curl -sSL https://install.python-poetry.org | POETRY_HOME=/usr/local python3 -

# Copy documentation
COPY ./docs /docs

# Bootstrap home
RUN adduser --shell /bin/zsh --disabled-password --gecos '' coder
RUN ln -s /docs /home/coder/docs
USER coder
WORKDIR /home/coder
COPY vscode_settings.json .local/share/code-server/Machine/settings.json
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

USER root
RUN mkdir /bootstrap
RUN cp -rf . /bootstrap/ && chown -R coder:coder /bootstrap

USER coder


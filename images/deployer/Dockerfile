# This digest is intentionally pinned. Refresh it only through the platform-image review workflow.
FROM amazonlinux@sha256:065856aabb1ddab0441f4024dfbba116cc760286858a53ec74e6a1218af979ee

ARG POWERSHELL_VERSION=7.4.6
ARG AWS_CLI_VERSION=2.36.42
ARG TERRAFORM_VERSION=1.15.8
ARG KUBECTL_VERSION=v1.35.0
ARG HELM_VERSION=v3.17.4

# Amazon Linux supplies curl-minimal in the pinned base. Installing curl would
# replace it and makes its historical repository set conflict.
RUN dnf -y update \
    && dnf -y install tar gzip unzip java-17-amazon-corretto-headless \
    && curl --fail --silent --show-error --location -o /tmp/powershell.rpm "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/powershell-${POWERSHELL_VERSION}-1.rh.x86_64.rpm" \
    && dnf -y install /tmp/powershell.rpm \
    && curl --fail --silent --show-error --location -o /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWS_CLI_VERSION}.zip" \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install --update \
    && curl --fail --silent --show-error --location -o /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
    && unzip -q /tmp/terraform.zip -d /usr/local/bin \
    && curl --fail --silent --show-error --location -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod 0755 /usr/local/bin/kubectl \
    && curl --fail --silent --show-error --location -o /tmp/helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    && tar -xzf /tmp/helm.tgz -C /tmp \
    && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm \
    && dnf clean all \
    && rm -rf /tmp/* /var/cache/dnf

RUN pwsh --version \
    && java -version \
    && aws --version \
    && terraform version \
    && kubectl version --client=true \
    && helm version --short

USER 10001
WORKDIR /workspace
ENTRYPOINT ["pwsh", "-NoLogo", "-NoProfile"]

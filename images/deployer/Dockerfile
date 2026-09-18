# Refresh the base and verification inputs through the reviewed image-build contract.
FROM amazonlinux@sha256:065856aabb1ddab0441f4024dfbba116cc760286858a53ec74e6a1218af979ee

ARG POWERSHELL_VERSION=7.4.6
ARG AWS_CLI_VERSION=2.36.42
ARG TERRAFORM_VERSION=1.15.8
ARG KUBECTL_VERSION=v1.35.0
ARG HELM_VERSION=v3.17.4

# Required reviewed SHA256 values; never derive these from the downloaded bytes.
ARG POWERSHELL_SHA256
ARG AWS_CLI_SHA256
ARG TERRAFORM_SHA256
ARG KUBECTL_SHA256
ARG HELM_SHA256
COPY images/deployer/verify-sha256.sh /usr/local/bin/verify-deployer-sha256
RUN for checksum in "${POWERSHELL_SHA256}" "${AWS_CLI_SHA256}" "${TERRAFORM_SHA256}" "${KUBECTL_SHA256}" "${HELM_SHA256}"; do \
        /bin/sh /usr/local/bin/verify-deployer-sha256 "$checksum" || exit 1; \
    done

# Amazon Linux supplies curl-minimal in the pinned base. Installing curl would
# replace it and makes its historical repository set conflict.
RUN dnf -y update \
    && dnf -y install tar gzip unzip java-17-amazon-corretto-headless \
    && curl --fail --silent --show-error --location -o /tmp/powershell.rpm "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/powershell-${POWERSHELL_VERSION}-1.rh.x86_64.rpm" \
    && /bin/sh /usr/local/bin/verify-deployer-sha256 "${POWERSHELL_SHA256}" /tmp/powershell.rpm \
    && dnf -y install /tmp/powershell.rpm \
    && curl --fail --silent --show-error --location -o /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWS_CLI_VERSION}.zip" \
    && /bin/sh /usr/local/bin/verify-deployer-sha256 "${AWS_CLI_SHA256}" /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install --update \
    && curl --fail --silent --show-error --location -o /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
    && /bin/sh /usr/local/bin/verify-deployer-sha256 "${TERRAFORM_SHA256}" /tmp/terraform.zip \
    && unzip -q /tmp/terraform.zip -d /usr/local/bin \
    && curl --fail --silent --show-error --location -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && /bin/sh /usr/local/bin/verify-deployer-sha256 "${KUBECTL_SHA256}" /usr/local/bin/kubectl \
    && chmod 0755 /usr/local/bin/kubectl \
    && curl --fail --silent --show-error --location -o /tmp/helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    && /bin/sh /usr/local/bin/verify-deployer-sha256 "${HELM_SHA256}" /tmp/helm.tgz \
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

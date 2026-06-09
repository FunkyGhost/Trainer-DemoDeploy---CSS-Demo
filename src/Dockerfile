# Trivial image — the build content is irrelevant to the repro.
# The failure happens at the ACR authentication step, before any push.
FROM mcr.microsoft.com/cbl-mariner/base/core:2.0
RUN echo "tdd-multi-identity-acr-auth repro (case 2605130050002742)" > /etc/repro.txt
CMD ["/bin/sh", "-c", "cat /etc/repro.txt"]

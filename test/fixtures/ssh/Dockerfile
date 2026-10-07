# TASK-43: a disposable sshd for the SSH ExecutionContext integration test
# (`src/ssh.zig`). Adapted from the TASK-42 spike (spikes/ssh-controlmaster/).
# The authorized key is bind-mounted at start, so the image never holds key
# material; the test generates a throwaway key in its own temporary directory.
FROM ubuntu:24.04
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends openssh-server procps \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd \
 && useradd -m -s /bin/bash conduit \
 && mkdir -p /home/conduit/project/sub "/home/conduit/project/it's \$(x) \`y\`" \
 && printf 'conduit-ssh-file\n' > /home/conduit/project/notes.txt \
 && touch /home/conduit/project/alpha /home/conduit/project/beta \
 && chown -R conduit:conduit /home/conduit
# Key-only auth and VERBOSE logging, so every authentication is one
# "Accepted publickey" line on sshd's stderr (docker logs).
RUN printf '%s\n' \
    'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' \
    'PermitRootLogin no' \
    'LogLevel VERBOSE' \
    'MaxSessions 10' \
    > /etc/ssh/sshd_config.d/conduit.conf
EXPOSE 22
CMD ["/bin/sh", "-c", "install -o conduit -g conduit -m 700 -d /home/conduit/.ssh && install -o conduit -g conduit -m 600 /conduit-key.pub /home/conduit/.ssh/authorized_keys && ssh-keygen -A >/dev/null && exec /usr/sbin/sshd -D -e"]

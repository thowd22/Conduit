# TASK-42 spike (THROWAWAY): a disposable sshd for the ControlMaster prototype.
# Never used by the real build. The authorized key is bind-mounted at start, so
# the image never holds key material.
FROM ubuntu:24.04
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends openssh-server \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd \
 && useradd -m -s /bin/bash spike \
 && mkdir -p /home/spike/project \
 && printf 'conduit-spike-file\n' > /home/spike/project/notes.txt \
 && touch /home/spike/project/alpha /home/spike/project/beta \
 && chown -R spike:spike /home/spike
# Key-only auth and VERBOSE logging, so every authentication is one
# "Accepted publickey" line on sshd's stderr (docker logs).
RUN printf '%s\n' \
    'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' \
    'PermitRootLogin no' \
    'LogLevel VERBOSE' \
    'MaxSessions 10' \
    > /etc/ssh/sshd_config.d/spike.conf
EXPOSE 22
CMD ["/bin/sh", "-c", "install -o spike -g spike -m 700 -d /home/spike/.ssh && install -o spike -g spike -m 600 /spike-key.pub /home/spike/.ssh/authorized_keys && ssh-keygen -A >/dev/null && exec /usr/sbin/sshd -D -e"]

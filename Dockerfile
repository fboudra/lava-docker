FROM debian:sid

RUN export LANG=en_US.UTF-8

# Remove comment to enable local proxy server (e.g. apt-cacher-ng)
#RUN echo 'Acquire::http { Proxy "http://dockerproxy:3142"; };' >> /etc/apt/apt.conf.d/01proxy

## Install debian packages used by the container
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    postgresql \
    qemu-system \
    expect \
    openssh-server \
    vim \
    android-tools-fastboot \
    cu \
    screen \
    lava-dispatcher \
    lava-tool \
    lava-coordinator \
    lava-dev \
    linaro-image-tools \
 && rm -rf /var/lib/apt/lists/*

# Add services helper utilities to start and stop LAVA
COPY stop.sh .
COPY start.sh .

# Add some job submission utilities
COPY submit.py /tools/
COPY submityaml.py /tools/
COPY submittestjob.sh .
COPY kvm-basic.json /tools/
COPY kvm-qemu-aarch64.json /tools/
COPY qemu.yaml /tools/

# Add support for SSH for remote configuration
RUN mkdir /var/run/sshd && \
    sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    echo 'root:password' | chpasswd
EXPOSE 22

# Install lava and configure apache to run the lava server
COPY preseed.txt /data/
RUN apt-get update && \
    service postgresql start && \
    debconf-set-selections < /data/preseed.txt && \
    DEBIAN_FRONTEND=noninteractive apt-get -y install lava && \
    a2dissite 000-default && \
    a2ensite lava-server && \
    /stop.sh && \
    rm -rf /var/lib/apt/lists/* && \
    hostname > /hostname  #log the hostname used during install for the slave name

# Create a admin user (Insecure note, this creates a default user, username: admin/admin)
COPY createsuperuser.sh /tools/
RUN /start.sh && /tools/createsuperuser.sh && /stop.sh

# Add devices to the server (ugly, but it works)
COPY add-kvm-to-lava.sh /tools/
RUN /start.sh && /tools/add-kvm-to-lava.sh && \
    /usr/share/lava-server/add_device.py kvm kvm01 && \
    /usr/share/lava-server/add_device.py qemu-aarch64 qemu-aarch64-01 && \
    echo "root_part=1" >> /etc/lava-dispatcher/devices/kvm01.conf && \
    /stop.sh

# Add a Pipeline device
RUN /start.sh && mkdir -p /etc/dispatcher-config/devices && \
    cp /usr/lib/python2.7/dist-packages/lava_scheduler_app/tests/devices/qemu01.jinja2 \
       /etc/dispatcher-config/devices/ && \
    echo "{% set arch = 'amd64' %}">> /etc/dispatcher-config/devices/qemu01.jinja2 && \
    echo "{% set base_guest_fs_size = 2048 %}" >> /etc/dispatcher-config/devices/qemu01.jinja2 && \
    lava-server manage device-dictionary --hostname qemu01 \
       --import /etc/dispatcher-config/devices/qemu01.jinja2 && \
    /stop.sh

# CORTEX-M3: add python-sphinx-bootstrap-theme
RUN sudo apt-get update && apt-get install -y python-sphinx-bootstrap-theme \
 && rm -rf /var/lib/apt/lists/*

# CORTEX-M3: apply patches to enable cortex-m3 support
COPY monitor-test-jobs-hack.patch /tools
RUN /start.sh && \
    echo "add build then install capability to debian-dev-build.sh" && \
    echo "cd \${DIR} && dpkg -i *.deb" >> /usr/share/lava-server/debian-dev-build.sh && \
    echo "adding patches for dispatcher" && \
    cd / && git clone https://github.com/linaro/lava-dispatcher && cd /lava-dispatcher && git checkout master && \
    #cd /lava-dispatcher && git checkout e545969affcc449d833b2fcd3b8efe2d966f72a3 && \
    cd /lava-dispatcher && git fetch https://review.linaro.org/lava/lava-dispatcher refs/changes/11/12711/5 && git cherry-pick FETCH_HEAD && \
    echo "adding patches for server" && \
    cd / && git clone https://github.com/linaro/lava-server && cd /lava-server && git checkout master && \
    #cd /lava-server && git checkout 30facc1290ad2dd28ed4ad41ff971546e360f92e && \
    cd /lava-server && git fetch https://review.linaro.org/lava/lava-server refs/changes/70/12670/1 && git cherry-pick FETCH_HEAD && \
    cd /lava-server && git fetch https://review.linaro.org/lava/lava-server refs/changes/23/12723/2 && git cherry-pick FETCH_HEAD && \
    cd /lava-server && git am /tools/monitor-test-jobs-hack.patch && \
    echo "Installing patched versions of dispatcher & server" && \
    cd /lava-dispatcher && /usr/share/lava-server/debian-dev-build.sh -p lava-dispatcher && \
    cd /lava-server && /usr/share/lava-server/debian-dev-build.sh -p lava-server &&\
    /stop.sh

# CORTEX-M3: add a qemu-cortex-m3 Pipeline device
COPY qemu-cortex-m3.yaml /tools/
COPY qemu-cortex-m3-01.jinja2 /etc/dispatcher-config/devices/
RUN /start.sh && \
    lava-server manage device-dictionary --hostname qemu-cortex-m3-01 \
       --import /etc/dispatcher-config/devices/qemu-cortex-m3-01.jinja2 && \
    /stop.sh

# To run jobs using python XMLRPC, we need the API token (really ugly)
COPY getAPItoken.sh /tools/
RUN /start.sh && /tools/getAPItoken.sh && /stop.sh

EXPOSE 80
CMD /start.sh && bash
## Following CMD option starts the lava container without a shell and exposes the logs
#CMD /start.sh && tail -f /var/log/lava-*/*

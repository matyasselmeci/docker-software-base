# Default to EL9 builds
ARG IMAGE_BASE=quay.io/almalinux/almalinux:9

FROM $IMAGE_BASE

# "ARG IMAGE_BASE" needs to be here again because the previous instance has gone out of scope.
ARG IMAGE_BASE=quay.io/almalinux/almalinux:9
ARG BASE_YUM_REPO=testing
ARG OSG_RELEASE=23
# Set BOOTSTRAP to true to not install OSG packages or enable OSG repos
ARG BOOTSTRAP=false

LABEL maintainer OSG Software <help@osg-htc.org>

RUN \
    log () { printf "\n%s\t%s\n\n" "$(date '+%F %X %z')" "$*" ; } ; \
    # Attempt to grab the major version from the tag \
    DVER=$(egrep -o '[0-9][\.0-9]*$' <<< "$IMAGE_BASE" | cut -d. -f1); \
    if  [[ $DVER == 7 ]]; then \
       YUM_PKG_NAME="yum-plugin-priorities"; \
       yum-config-manager \
         --setopt=skip_missing_names_on_install=False \
         --setopt=skip_missing_names_on_update=False \
         --save > /dev/null; \
    else \
       YUM_PKG_NAME="yum-utils"; \
    fi && \
    log "Updating OS YUM cache" && time \
    yum makecache && \
    log "Updating OS" && time \
    yum distro-sync -y && \
    if [[ $OSG_RELEASE =~ ^[0-9][0-9]$ ]]; then \
       OSG_URL=https://repo.opensciencegrid.org/osg/${OSG_RELEASE}-main/osg-${OSG_RELEASE}-main-el${DVER}-release-latest.rpm; \
    else \
       OSG_URL=https://repo.opensciencegrid.org/osg/${OSG_RELEASE}/osg-${OSG_RELEASE}-el${DVER}-release-latest.rpm; \
    fi && \
    log "Installing EPEL/OSG repo packages" && time \
    yum -y install $OSG_URL \
                   epel-release \
                   $YUM_PKG_NAME && \
    if [[ $DVER == 8 ]]; then \
        yum-config-manager --enable powertools && \
        yum-config-manager --setopt=install_weak_deps=False --save > /dev/null; \
    fi && \
    if [[ $DVER == 9 ]]; then \
        yum-config-manager --enable crb && \
        yum-config-manager --setopt=install_weak_deps=False --save > /dev/null; \
    fi && \
    if [[ $BOOTSTRAP == "true" ]]; then \
        yum-config-manager --disable 'osg*'; \
    elif [[ $BASE_YUM_REPO != "release" ]]; then \
        yum-config-manager --enable osg-${BASE_YUM_REPO}; \
        yum-config-manager --enable osg-upcoming-${BASE_YUM_REPO}; \
    else \
        yum-config-manager --enable osg-upcoming; \
    fi && \
    log "Updating EPEL/OSG YUM cache" && time \
    yum makecache && \
    log "Installing common software" && time \
    yum -y install supervisor \
                   cronie \
                   fetch-crl \
                   which \
                   less \
                   rpmdevtools \
                   fakeroot \
                   /usr/bin/ps \
                   && \
    if [[ $BOOTSTRAP != "true" ]]; then \
        yum -y install osg-ca-certs; \
    fi && \
    if [[ $DVER == 8 ]]; then \
        log "Installing crypto-policies-scripts (EL8)" && time \
        yum -y install crypto-policies-scripts; \
    fi && \
    # avoid condor 23.x release candidates and dailies until we get an all clear from the devs \
    # FIXME this code can be removed once the bad versions are gone \
    if [[ $BOOTSTRAP != "true" && $OSG_RELEASE == 23 ]]; then \
        # OSG 23 implies el8+ \
        dnf -y install dnf-plugin-versionlock && \
        # versionlock locks globs, not ranges so this is annoying \
        # the issue got fixed in 23.4.0-0.706796 and 23.5.0-0.706930 \
        # \
        # handle 23.4.0 -- avoid [0.700000,0.706796): \
        dnf versionlock exclude "condor-0:23.4.0-0.70[0-6]*" --enablerepo="osg-upcoming*" && \
        dnf versionlock del     "condor-0:23.4.0-0.70679[6-9]*" \
                                "condor-0:23.4.0-0.706[8-9]*" --enablerepo="osg-upcoming*" && \
        # \
        # handle 23.5.* -- avoid [0.70000,0.706930): \
        dnf versionlock exclude "condor-0:23.5.0-0.70[0-6]*" --enablerepo="osg-upcoming*" && \
        dnf versionlock del     "condor-0:23.5.0-0.7069[3-9]*" --enablerepo="osg-upcoming*" && \
        # verify the results \
        dnf versionlock list | sort; \
    fi && \
    log "Cleaning up YUM metadata" && time \
    yum clean all && \
    rm -rf /var/cache/yum/ && \
    # Impatiently ignore the Yum mirrors
    sed -i 's/\#baseurl/baseurl/; s/mirrorlist/\#mirrorlist/' \
        /etc/yum.repos.d/osg*.repo && \
    # Disable gpgcheck for devops, till we get them rebuilt for SOFTWARE-5422
    if [[ $OSG_RELEASE == "3.6" ]]; then \
       sed -i 's/gpgcheck=1/gpgcheck=0/' \
              /etc/yum.repos.d/devops*.repo; \
    fi && \
    mkdir -p /etc/osg/image-{cleanup,init}.d/ && \
    # Support old init script dir name
    ln -s /etc/osg/image-{init,config}.d

COPY bin/* /usr/local/bin/
COPY supervisord_startup.sh /usr/local/sbin/
COPY crond_startup.sh /usr/local/sbin/
COPY container_cleanup.sh /usr/local/sbin/
COPY supervisord.conf /etc/
COPY 00-cleanup.conf /etc/supervisord.d/
COPY update-certs-rpms-if-present.sh /etc/cron.hourly/
COPY cron.d/* /etc/cron.d/
COPY image-init.d/* /etc/osg/image-init.d/
RUN chmod go-w /etc/supervisord.conf /usr/local/sbin/* /etc/cron.*/*
# For OKD, which runs as non-root user and root group
RUN chmod g+w /var/log /var/log/supervisor /var/run

# Allow use of SHA1 certificates.
# Accepted values are "YES" (enable them, even on EL9), "NO" (disable them, even on EL8), "DEFAULT" (use OS default).
# No effect on EL7.
ENV ENABLE_SHA1=DEFAULT

CMD ["/usr/local/sbin/supervisord_startup.sh"]

############################################################
# Dockerfile
############################################################

# Set the base image
FROM centos:latest

############################################################
# Configuration
############################################################

############################################################
# Entrypoint
############################################################
ADD rootfs /

############################################################
# Installation
############################################################
RUN set -xe &&\
	yum install bash net-tools which iptables iproute -y &&\
	# Prepare
	yum install svn gcc gcc-c++ make libgcrypt-devel gnutls-devel perl-core -y &&\
	mkdir -p /tmp/src &&\
	# Clone from Source
	svn co --non-interactive --trust-server-cert -r 550 https://svn.unix-ag.uni-kl.de/vpnc/trunk/ /tmp/src &&\
	cd /tmp/src &&\
	# Build
	make &&\
	make install &&\
	# CleanUp
	yum remove svn gcc gcc-c++ make libgcrypt-devel gnutls-devel perl-core -y &&\
	rm -rf /tmp/src

############################################################
# Execution
############################################################
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["vpnc", "--version"]

#!/bin/bash
set -ex

/data/Software/mydan/perl/bin/cpan install Net::LDAP Crypt::RC4::XS
rm -rf /data/Software/mydan/perl/man
rm -rf /root/.cpan

cd /data/Software/mydan
tar -zcf perl.tar.gz perl

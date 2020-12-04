#!/bin/bash

set -e 

if [ "X$OPEN_C3_ADDR" == "X" ]; then
    echo 'OPEN_C3_ADDR nofind'
    exit 1
fi

if [[ -d /opt/mydan && ! -L /opt/mydan ]]; then
    if [[ -d /data/mydan ]]; then
        rm -rf /data/mydan
    fi
    mv /opt/mydan /data/
fi

mkdir -p /data/mydan
ln -snf /data/mydan /opt/mydan

MYDanPATH=/data/mydan

#MYDAN_REPO_PRIVATE
#export MYDAN_REPO_PRIVATE="http://10.10.10.10:9999"

curl -s http://$OPEN_C3_ADDR/api/scripts/MYDan_mydan_update.sh|bash

curl --connect-timeout 5 -m 5 myip.ipip.net 2>/dev/null|awk '{print $2}'|awk -F： '{print $2}' >  $MYDanPATH/etc/ips


if [[ -f $MYDanPATH/etc/iamproxy ]];then
    rm $MYDanPATH/etc/iamproxy
fi

if [ -f /opt/mydan/dan/.success ]; then

    if [[ -d $MYDanPATH/etc/agent/auth/ && ! -f $MYDanPATH/etc/agent/auth/c3_test.pub ]]; then
        wget http://$OPEN_C3_ADDR/api/scripts/c3_test.pub -O $MYDanPATH/etc/agent/auth/c3_test.pub
    fi

    echo "UPDATE OPEN-C3 AGENT: SUCCESS!!!"
    exit
fi

$MYDanPATH/dan/bootstrap/bin/bootstrap --install

killall -V >/dev/null 2>&1 ||yum install psmisc -y || apt-get install psmisc || echo "PLEASE INSTALL psmisc!!!"

killall -q 021029e.mydan.bootstrap.master || echo "NO /opt/mydan PROCESS"
rm -f /etc/cron.d/mydan_bootstrap_cron_021029e || echo "NO mydan_bootstrap_cron_021029e"

setsid -V >/dev/null 2>&1 || echo "NO setsid"

if [ $? -eq 0 ]
then
    setsid $MYDanPATH/dan/bootstrap/bin/bootstrap --restart
else
    $MYDanPATH/dan/bootstrap/bin/bootstrap --restart
fi

wget http://$OPEN_C3_ADDR/api/scripts/c3_test.pub -O $MYDanPATH/etc/agent/auth/c3_test.pub

if [[ -d $MYDanPATH/var/run/filecache ]]; then
    rm -rf $MYDanPATH/var/run/filecache
fi

touch /opt/mydan/dan/.success
echo "INSTALL OPEN-C3 AGENT: SUCCESS!!!"

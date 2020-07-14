#!/bin/bash

# Custom Vars

SRCWEB="x.x.x.1"  # source web server (public)
SRCDB="db.source.internal" # source mysql server (private network)

DESTWEB="x.x.x.2" # destination web server (public)
DESTDB="db.dest.internal" # destination mysql server (private network)

DOMAIN1="example.com"  # primary domain (for DNS changes)
DOMAIN2="dev.example.com" # additional domain (for DNS changes)

MYSQLUSR="testuser"  # MySQL User - must exist on both servers
MYSQLDB="TESTDB"# MySQL Database to migrate - must exist on both servers
MYSQLPW="P@SSWORD" # MySQL Password - must match on both servers
IGNORETABLES="$MYSQLDB.404errors,$MYSQLDB.paypal_redir" # Tables to ignore during MySQL dump

AWSZONEID="example-zone-id"
# Init  - used by script, don't change

THISDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
FILESDIR="$THISDIR/../files"
set -e    # Die on any error

# Make sure only root can run our script

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

echo "##########################################################"
echo "#"
echo "#  Stopping/disabling services and cron jobs on source server"
echo "#"
echo "##########################################################"
echo ""

if [[ $1 == LIVE ]]; then
    echo "LIVE RUN! Buckle up."

ssh root@$SRCWEB 'service httpd stop && chkconfig httpd off && crontab -r'

else
    echo 'LIVE argument not supplied. Assuming dry run - no source changes'
fi

echo ""
echo "##########################################################"
echo "#"
echo "#  Updating DNS Records"
echo "#"
echo "##########################################################"
echo ""

if [[ $1 == LIVE ]]; then
    echo "LIVE RUN! Buckle up."

aws route53 change-resource-record-sets --hosted-zone-id $AWSZONEID --change-batch '{ "Comment": "AWS Host", "Changes": [ { "Action": "UPSERT", "ResourceRecordSet": { "Name": "$DOMAIN1", "Type": "A", "TTL":120, "ResourceRecords": [ { "Value": "$DESTWEB" } ] } } ] }'
aws route53 change-resource-record-sets --hosted-zone-id $AWSZONEID --change-batch '{ "Comment": "AWS Host", "Changes": [ { "Action": "UPSERT", "ResourceRecordSet": { "Name": "$DOMAIN2", "Type": "A", "TTL":120, "ResourceRecords": [ { "Value": "$DESTWEB" } ] } } ] }'

else
    echo 'LIVE argument not supplied. Assuming dry run - no DNS changes'
fi

echo ""
echo "##########################################################"
echo "#"
echo "#  Dropping/truncating databases on destination server"
echo "#"
echo "##########################################################"
echo ""

mysql -h $DESTDB -u $MYSQLUSR -p$MYSQLPW $MYSQLDB < ./migration-dest-prep.sql

echo ""
echo "##########################################################"
echo "#"
echo "#  Stopping/disabling httpd service on destination during migration"
echo "#"
echo "##########################################################"
echo ""

service httpd stop
chkconfig httpd off

echo ""
echo "##########################################################"
echo "#"
echo "#  Rsyncing www data from source to destinations"
echo "#"
echo "##########################################################"
echo ""

rsync -av root@$SRCWEB:/var/www/ /var/www/

echo ""
echo "##########################################################"
echo "#"
echo "#  mysqldump from source directly into destination mysql server over SSH"
echo "#       "
echo "#"
echo "##########################################################"
echo ""

ssh root@$SRCWEB \
   "mysqldump -u $MYSQLUSR \
    --host $SRCDB \
    --databases $MYSQLDB \
    --single-transaction \
    --compress \
    --order-by-primary  \
    --ignore-table={$IGNORETABLES} \
    -p$MYSQLPW" | \
    pv | \
    mysql -u $MYSQLUSR \
        --host=$DESTDB \
        -p$MYSQLPW

echo ""
echo "##########################################################"
echo "#"
echo "#  Applying config transformations and setting file ownership on destination"
echo "#"
echo "##########################################################"
echo ""

grep -rl "$SRCDB" /var/www/secure/*.php | xargs sed -i "s/$SRCDB/$DESTDB/g"
grep -rl "$SRCDB" /var/www/secure/*.pl | xargs sed -i "s/$SRCDB/$DESTDB/g"
grep -rl "$SRCDB" /var/www/html/admin2/phpfn8.php | xargs sed -i "s/$SRCDB/$DESTDB/g"
cp -f /usr/src/repos/server-migration/testing/smtp_mail.php /var/www/html/vendors/frames/smtp_mail.php
chown -R apache:apache /var/www/*

echo ""
echo "##########################################################"
echo "#"
echo "#  Starting/enabling httpd service on destination"
echo "#"
echo "##########################################################"
echo ""

service httpd start
chkconfig httpd on

echo "##########################################################"
echo "#"
echo "#  Importing/enabling cron jobs"
echo "#"
echo "##########################################################"
echo ""

if [[ $1 == LIVE ]]; then
    echo "LIVE RUN! Buckle up."
install -C -m 750 "$FILESDIR"/etc/cron.d/prod-00 /etc/cron.d/prod-00
else
    echo 'LIVE argument not supplied. Assuming dry run - installing blank cron file'
install -C -m 750 "$FILESDIR"/etc/cron.d/prod-disabled /etc/cron.d/prod-00
fi

echo ""
echo "##########################################################"
echo "#"
echo "#  Migration Complete! Test $DOMAIN1 now"
echo "#"
echo "##########################################################"
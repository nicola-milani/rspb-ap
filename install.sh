rsync -av ./etc/ /etc
rsync -av ./usr/ /usr
chmod +x /usr/bin/manage.sh
/usr/bin/manage.sh --init

#!/bin/bash

cp /opt/soldr_observability/config/elasticsearch/* /usr/share/elasticsearch/config/

chmod -R 0775 /usr/share/elasticsearch/config

while true; do
    RETURNCODE=$(curl -s -o return_code.txt -w "%{http_code}" "http://elasticsearch:9200/")
    if [ $RETURNCODE == "401" ]; then
        echo "Connect to Elasticsearch was successful"
        break
    fi
    echo "Failed to connect to Elasticsearch"
    sleep 1
done

sleep 5

if [[ -f /usr/share/elasticsearch/config/passfile && $(cat /usr/share/elasticsearch/config/passfile) != "" ]]; then
    ELASTIC_PASS=$(cat /usr/share/elasticsearch/config/passfile)
    if [[ $MASTER_PASSWORD == $ELASTIC_PASS ]]; then
        echo "MASTER_PASSWORD env and password in /usr/share/elasticsearch/config/passfile is equel"
        RETURNCODE=$(curl -s -o return_code.txt -w "%{http_code}" -u "elastic:$ELASTIC_PASS" "http://elasticsearch:9200/_xpack/security/_authenticate")
        if [[ $RETURNCODE != "200" ]]; then
            echo "Password in /usr/share/elasticsearch/config/passfile is incorrect"
        else
            echo "Password in /usr/share/elasticsearch/config/passfile is correct"
        fi
    else
        echo "Change password to MASTER_PASSWORD env"
        RETURNCODE=$(curl -s -o return_code.txt -w "%{http_code}" -XPOST -u elastic:$ELASTIC_PASS 'http://elasticsearch:9200/_security/user/elastic/_password?pretty' -H 'Content-Type: application/json' -d '{"password": "'"$MASTER_PASSWORD"'"}')
        if [[ $RETURNCODE != "200" ]]; then
            echo "Change password failed"
        else
            echo "Successful password change"
            echo $MASTER_PASSWORD > /usr/share/elasticsearch/config/passfile
        fi
    fi
else
    echo "Generate new password and change default password"
    if [[ $MASTER_PASSWORD != "" ]]; then
        echo $MASTER_PASSWORD > /usr/share/elasticsearch/config/passfile
    else
        date +%s | sha256sum | base64 | head -c 20 > /usr/share/elasticsearch/config/passfile
    fi
    ELASTIC_PASS=$(cat /usr/share/elasticsearch/config/passfile)
    RETURNCODE=$(curl -s -o return_code.txt -w "%{http_code}" -XPOST -u elastic:changeme 'http://elasticsearch:9200/_security/user/elastic/_password?pretty' -H 'Content-Type: application/json' -d '{"password": "'"$ELASTIC_PASS"'"}')
    if [[ $RETURNCODE != "200" ]]; then
        echo "Change password failed"
    else
        echo "Successful password change"
    fi
fi

sleep infinity

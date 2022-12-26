#!/bin/bash

PASSWORD_FILE=/usr/share/elasticsearch/config/passfile
GRAFANA_KEY=/etc/grafana/ssl/grafana.key
GRAFANA_CRT=/etc/grafana/ssl/grafana.crt


if [[ -f "$GRAFANA_KEY" && -f "$GRAFANA_CRT" ]]; then
    echo "Grafana crt and key already exist."
else
    echo "Gen Grafana key and crt."
    mkdir /etc/grafana/ssl/
    mkdir ssl

    openssl genrsa -out ssl/server_ca.key 4096
    openssl req -new -x509 -days 391 -key ssl/server_ca.key \
    -subj "/C=RU/L=MO/O=VXControl/CN=VXControl SOLDR OBSERV CA" \
    -out ssl/server_ca.crt

    openssl req -newkey rsa:4096 -sha256 -nodes -keyout $GRAFANA_KEY \
    -subj "/C=RU/L=MO/O=VXControl/CN=soldr-observ.local" \
    -out ssl/grafana.csr

    openssl x509 -req -extfile <(printf "subjectAltName=DNS:soldr-observ.local, DNS:localhost\nkeyUsage=digitalSignature, nonRepudiation, keyEncipherment\nextendedKeyUsage=serverAuth") \
    -days 390 -in ssl/grafana.csr  \
    -CA ssl/server_ca.crt \
    -CAkey ssl/server_ca.key -CAcreateserial \
    -out $GRAFANA_CRT

    cat ssl/server_ca.crt >> $GRAFANA_CRT

    chmod g+r $GRAFANA_KEY

    rm -rf ssl
fi

if [[ -f "$PASSWORD_FILE" ]]; then
    ELASTIC_PASS=$(cat /usr/share/elasticsearch/config/passfile)
    if [[ -z "$ELASTIC_PASS" ]]; then
        echo "Password not found in passfile"
        exit 1
    else
        if grep -RFq 'PASSWORD-TEMPLATE' config/jaeger/config.yml ; then 
            echo "Firts deploy, replace PASSWORD-TEMPLATE to MASTER_PASSWORD"
            sed -i 's/PASSWORD-TEMPLATE/'"$ELASTIC_PASS"'/g' config/jaeger/config.yml
        else
            echo "Change Elasticsearch password in Jaeger config.yml to new MASTER_PASSWORD"
            OLD_PASSWORD=$(grep "admin_password" config/jaeger/config.yml | awk '{print $2}')
            if [[ $OLD_PASSWORD == $ELASTIC_PASS ]]; then
                echo "MASTER_PASSWORD the same"
            else
                echo "Update MASTER_PASSWORD in Jaeger config.yml"
                if [[ $OLD_PASSWORD == * ]]; then
                    OLD_PASSWORD=$(echo $OLD_PASSWORD | sed 's|\*|\\\*|g')
                fi
                sed -i 's|'"$OLD_PASSWORD"'|'"$ELASTIC_PASS"'|g' config/jaeger/config.yml    
            fi
        fi
    fi
fi

echo "Copy config files to containers dst dirs"
cp -R config/grafana/* /etc/grafana/
cp -R config/grafana/dashboards/* /var/lib/grafana/dashboards/
cp -R config/jaeger/* /etc/jaeger/
cp -R config/otelcontribcol/* /etc/otel/

chown -R grafana /etc/grafana
chown -R grafana /var/lib/grafana
echo "Configs and secrets copied successful"
sleep 10

echo "Check Elasticsearch"
while true; do
    RETURN_CODE=$(curl -s -o return_code -w "%{http_code}" \
        -u elastic:$ELASTIC_PASS \
        -k 'http://elasticsearch.local:9200/_cluster/health?wait_for_status=yellow&timeout=50s&pretty')
    if [[ $RETURN_CODE != 200 ]]; then
        echo "Waiting for Elasticsearch ..."
        sleep 1
    else 
        echo "Elasticsearch alive with correct config."
        break
    fi
done

echo "Check ILM policy for Jaeger"
ELASTIC_ILM_POLICY_RETURN_CODE=$(curl -u elastic:$ELASTIC_PASS -s 'http://elasticsearch.local:9200/_ilm/policy/jaeger-ilm-policy?pretty' | jq -r '.["jaeger-ilm-policy"].version')

if [[ $ELASTIC_ILM_POLICY_RETURN_CODE == null ]]; then
    echo "Create ILM policy for Jaeger"
    ELASTIC_CREATE_ILM_RETURN_CODE=$(curl -X PUT -u elastic:$ELASTIC_PASS -s 'http://elasticsearch.local:9200/_ilm/policy/jaeger-ilm-policy' \
        -H 'Content-Type: application/json; charset=utf-8' \
        -d '{"policy": {"phases": {"hot": {"min_age": "0ms","actions": {"rollover": {"max_age": "1d"},"set_priority": {"priority": 100}}},"delete": {"min_age": "14d","actions": {"delete": {}}}}}}' | jq -r '.acknowledged')
    if [[ $ELASTIC_CREATE_ILM_RETURN_CODE == "true" ]]; then
        echo "ILM policy for Jaeger created successfully"
        echo "Create Jaeger index temptlate jaeger-span, jaeger-service, jaeger-dependencies"
        JAEGER_SPAN_INDEX_TEMPLATE_RETURN_CODE=$(curl -X PUT -u elastic:$ELASTIC_PASS -s 'http://elasticsearch.local:9200/_template/jaeger-span' \
            -H 'Content-Type: application/json; charset=utf-8' \
            -d '{"index_patterns":["jaeger-span-*"],"settings":{"index":{"lifecycle":{"name":"jaeger-ilm-policy","rollover_alias":"jaeger-span-write"},"mapping":{"nested_fields":{"limit":"50"}},"requests":{"cache":{"enable":"true"}},"number_of_shards":"1","number_of_replicas":"0"}},"mappings":{"dynamic_templates":[{"span_tags_map":{"path_match":"tag.*","mapping":{"ignore_above":256,"type":"keyword"}}},{"process_tags_map":{"path_match":"process.tag.*","mapping":{"ignore_above":256,"type":"keyword"}}}],"properties":{"traceID":{"ignore_above":256,"type":"keyword"},"process":{"properties":{"tag":{"type":"object"},"serviceName":{"ignore_above":256,"type":"keyword"},"tags":{"dynamic":false,"type":"nested","properties":{"tagType":{"ignore_above":256,"type":"keyword"},"value":{"ignore_above":256,"type":"keyword"},"key":{"ignore_above":256,"type":"keyword"}}}}},"startTimeMillis":{"format":"epoch_millis","type":"date"},"references":{"dynamic":false,"type":"nested","properties":{"traceID":{"ignore_above":256,"type":"keyword"},"spanID":{"ignore_above":256,"type":"keyword"},"refType":{"ignore_above":256,"type":"keyword"}}},"flags":{"type":"integer"},"operationName":{"ignore_above":256,"type":"keyword"},"parentSpanID":{"ignore_above":256,"type":"keyword"},"tags":{"dynamic":false,"type":"nested","properties":{"tagType":{"ignore_above":256,"type":"keyword"},"value":{"ignore_above":256,"type":"keyword"},"key":{"ignore_above":256,"type":"keyword"}}},"spanID":{"ignore_above":256,"type":"keyword"},"duration":{"type":"long"},"startTime":{"type":"long"},"tag":{"type":"object"},"logs":{"dynamic":false,"type":"nested","properties":{"fields":{"dynamic":false,"type":"nested","properties":{"tagType":{"ignore_above":256,"type":"keyword"},"value":{"ignore_above":256,"type":"keyword"},"key":{"ignore_above":256,"type":"keyword"}}},"timestamp":{"type":"long"}}}}},"aliases":{"jaeger-span-read":{}}}' | jq -r '.acknowledged')
        JAEGER_SERVICE_INDEX_TEMPLATE_RETURN_CODE=$(curl -X PUT -u elastic:$ELASTIC_PASS -s 'http://elasticsearch.local:9200/_template/jaeger-service' \
            -H 'Content-Type: application/json; charset=utf-8' \
            -d '{"index_patterns":["jaeger-service-*"],"settings":{"index":{"lifecycle":{"name":"jaeger-ilm-policy","rollover_alias":"jaeger-service-write"},"mapping":{"nested_fields":{"limit":"50"}},"requests":{"cache":{"enable":"true"}},"number_of_shards":"1","number_of_replicas":"0"}},"mappings":{"dynamic_templates":[{"span_tags_map":{"path_match":"tag.*","mapping":{"ignore_above":256,"type":"keyword"}}},{"process_tags_map":{"path_match":"process.tag.*","mapping":{"ignore_above":256,"type":"keyword"}}}],"properties":{"operationName":{"ignore_above":256,"type":"keyword"},"serviceName":{"ignore_above":256,"type":"keyword"}}},"aliases":{"jaeger-service-read":{}}}' | jq -r '.acknowledged')
        if [[ $JAEGER_SPAN_INDEX_TEMPLATE_RETURN_CODE == "true" && $JAEGER_SERVICE_INDEX_TEMPLATE_RETURN_CODE == "true" ]]; then
            echo "Jaeger index template created successfully"
            echo "Create Jaeger indexes"
            JAEGER_SPAN_INDEX_RETURN_CODE=$(curl -X PUT -u elastic:$ELASTIC_PASS -s 'http://elasticsearch.local:9200/jaeger-span-000001' \
                -H 'Content-Type: application/json; charset=utf-8' \
                -d '{"aliases" : {"jaeger-span-write": {"is_write_index": "true"}},"settings" : {"number_of_shards" : 1,"number_of_replicas" : 0}}' | jq -r '.acknowledged')
            JAEGER_SERVICE_INDEX_RETURN_CODE=$(curl -X PUT -u elastic:$ELASTIC_PASS -s 'http://elasticsearch.local:9200/jaeger-service-000001' \
                -H 'Content-Type: application/json; charset=utf-8' \
                -d '{"aliases" : {"jaeger-service-write": {"is_write_index": "true"}},"settings" : {"number_of_shards" : 1,"number_of_replicas" : 0}}' | jq -r '.acknowledged')
            if [[ $JAEGER_SPAN_INDEX_RETURN_CODE == "true" && $JAEGER_SERVICE_INDEX_RETURN_CODE == "true" ]];then
                echo "Jaeger indexes created successfully"
                touch /opt/soldr_observability/healthcheck
            else
                echo "Failed to create Jaeger indexes"
            fi
        else
            echo "Failed to create Jaeger index templates"
        fi
    else
        echo "Failed to create ILM policy for Jaeger"
    fi
else
    echo "ILM policy for Jaeger alrady exist"
    touch /opt/soldr_observability/healthcheck
fi

sleep infinity

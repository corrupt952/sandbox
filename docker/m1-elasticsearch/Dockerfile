FROM docker.elastic.co/elasticsearch/elasticsearch-oss:6.8.23

RUN bin/elasticsearch-plugin install analysis-kuromoji \
    && bin/elasticsearch-plugin install analysis-icu

EXPOSE 9200

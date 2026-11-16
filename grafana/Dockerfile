FROM grafana/grafana:11.3.0
ENV GF_AUTH_ANONYMOUS_ENABLED=true GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer GF_SECURITY_ADMIN_PASSWORD=shopstream
COPY provisioning /etc/grafana/provisioning
COPY dashboards /var/lib/grafana/dashboards

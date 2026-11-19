"""Add the same-origin Agno SSE route to a Frappe Docker Nginx template."""

import argparse
from pathlib import Path

AGNO_LOCATION = """location ^~ /tai-agno/ {
		resolver 127.0.0.11 valid=10s ipv6=off;
		set $tai_agno_backend tai-agno:7777;
		rewrite ^/tai-agno(/.*)$ /sites/${FRAPPE_SITE_NAME_HEADER}$1 break;
		proxy_http_version 1.1;
		proxy_set_header Host $host;
		proxy_set_header Cookie "";
		proxy_set_header Connection "";
		proxy_hide_header Set-Cookie;
		proxy_buffering off;
		proxy_cache off;
		gzip off;
		proxy_read_timeout ${PROXY_READ_TIMEOUT};
		proxy_pass http://$tai_agno_backend;
	}"""


def add_agno_route(template: str) -> str:
    if AGNO_LOCATION in template:
        return template
    if (template.count("location /assets {") != 1 or "${FRAPPE_SITE_NAME_HEADER}" not in template
            or "${PROXY_READ_TIMEOUT}" not in template or "/tai-agno/" in template):
        raise ValueError("Unsupported Nginx template or conflicting Agno route")
    return template.replace("location /assets {", AGNO_LOCATION + "\n\n\tlocation /assets {")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("template", type=Path)
    args = parser.parse_args()
    print(add_agno_route(args.template.read_text()), end="")

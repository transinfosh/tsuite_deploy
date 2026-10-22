"""Build and verify TBI query isolation without exposing Compose secrets."""
import argparse
import copy
import json
import re
import subprocess
from pathlib import Path

PYTHON = '/home/frappe/frappe-bench/env/bin/python'
SITES = '/home/frappe/frappe-bench/sites'
TEMPLATE = '/templates/nginx/frappe.conf.template'
UPSTREAM = 'http://tbi-query:8082'
SHARED_QUERY_LOCATIONS = {r'~ ^/tbi/shared/chart/[^/\r\n]+/?$'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def query_paths(locations):
    selectors = [s.strip() for s in re.findall(r'location\s+([^{}]+)\{', locations)]
    require(all(s.startswith('= ') or s in SHARED_QUERY_LOCATIONS for s in selectors), 'Query proxy must use exact locations or the declared shared chart route')
    paths = [s[2:].strip() if s.startswith('= ') else s for s in selectors]
    require(len(paths) == len(set(paths)) and bool(paths), 'Query route list is empty or duplicated')
    require('/api/method/tbi.bi.dashboard.execute_dashboard' in paths, 'Dashboard query route is missing')
    require(all(p.startswith(('/api/method/tbi.', '/api/v1/method/tbi.')) or p == '/tbi/shared_chart' or p in SHARED_QUERY_LOCATIONS for p in paths), 'Unexpected query route')
    require(not any('engine_gateway_bridge' in p for p in paths), 'Bridge must stay on the ordinary backend')
    return paths


def configure(original, image, root, template, locations):
    paths = query_paths(locations)
    require(template.count('location /assets {') == 1, 'Unsupported image Nginx template')
    result = copy.deepcopy(original)
    services = result['services']
    backend = services['backend']
    query = {
        'image': image, 'restart': 'unless-stopped', 'working_dir': SITES,
        'command': [PYTHON, '-m', 'tbi.query_service', '--host', '0.0.0.0', '--port', '8082'],
        'volumes': ['sites:' + SITES],
        'healthcheck': {
            'test': ['CMD', PYTHON, '-c', "import json,urllib.request; r=urllib.request.urlopen('http://127.0.0.1:8082/healthz',timeout=3); assert json.load(r)=={'service':'tbi-query','ok':True}"],
            'interval': '10s', 'timeout': '5s', 'retries': 6, 'start_period': '10s',
        },
    }
    for field in ('environment', 'extra_hosts', 'labels'):
        if field in backend:
            query[field] = copy.deepcopy(backend[field])
    # Copy secret mounts, but don't duplicate the sites mount on re-application.
    for volume in backend.get('volumes', []):
        require(isinstance(volume, str), 'Expected short volume syntax in the generated override')
        if volume.split(':')[1] != SITES:
            query['volumes'].append(volume)
    services['tbi-query'] = query
    frontend = services['frontend']
    frontend.setdefault('depends_on', {})['tbi-query'] = {'condition': 'service_healthy'}
    volumes = frontend.setdefault('volumes', [])
    volumes[:] = [v for v in volumes if v.split(':')[1] != TEMPLATE]
    volumes.append(f'{root}/nginx.tbi-query.template:{TEMPLATE}:ro')
    locations = locations.replace('X-Forwarded-Proto $scheme;', 'X-Forwarded-Proto $proxy_x_forwarded_proto;')
    nginx = template.replace('location /assets {', locations + '\n\tlocation /assets {') + '\n'
    check_routes(nginx, paths)
    return {'compose': result, 'nginx': nginx}


def check_routes(nginx, expected):
    routed = []
    for selector, body in re.findall(r'location\s+([^{}]+)\{([^{}]*)\}', nginx):
        if re.search(r'proxy_pass\s+' + re.escape(UPSTREAM) + r'\s*;', body):
            selector = selector.strip()
            require(selector.startswith('= ') or selector in SHARED_QUERY_LOCATIONS, 'Query proxy must use exact locations or the declared shared chart route')
            routed.append(selector[2:].strip() if selector.startswith('= ') else selector)
    require(sorted(routed) == sorted(expected), 'Active Nginx query routes differ from the image contract')
    require('engine_gateway_bridge' not in ' '.join(routed), 'Bridge routed into the query service')


def check_compose(config):
    services = config.get('services', {})
    require('tbi-query' in services, 'TBI requires the independent query service')
    query, backend, frontend = (services[n] for n in ('tbi-query', 'backend', 'frontend'))
    require(query.get('image') == backend.get('image'), 'Query and backend images must match')
    command = query.get('command', [])
    require(isinstance(command, list) and 'tbi.query_service' in command, 'Incorrect query service entry point')
    require(query.get('working_dir') == SITES, 'Query service must run in the shared sites directory')
    require(not query.get('ports'), 'Query service must not publish a host port')
    require(query.get('healthcheck', {}).get('test') and not query.get('healthcheck', {}).get('disable'), 'Query healthcheck is required')
    require(frontend.get('depends_on', {}).get('tbi-query', {}).get('condition') == 'service_healthy', 'Frontend must wait for query health')
    def mounts(service):
        return {v['target']: v for v in service.get('volumes', [])}
    bm, qm, fm = mounts(backend), mounts(query), mounts(frontend)
    for target, mount in bm.items():
        if target == SITES or target.startswith('/run/secrets/'):
            require(target in qm and qm[target].get('source') == mount.get('source') and qm[target].get('type') == mount.get('type'), 'Query sites or secret mounts differ from backend')
    require(SITES in qm and SITES in bm, 'Shared sites volume is required')
    require(TEMPLATE in fm and fm[TEMPLATE].get('read_only'), 'Frontend must mount the query routing template read-only')


def run(argv):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=60)
    # Compose and container output can contain credentials. Never include it in errors.
    require(result.returncode == 0, 'Deployment probe failed: ' + argv[0])
    return result.stdout


def verify(root, stack, site, engine_container=None):
    root = Path(root)
    compose = ['docker', 'compose', '--env-file', str(root / '.env'), '-p', 'frappe-' + stack]
    for file in ('frappe_docker/compose.yaml', 'frappe_docker/overrides/compose.redis.yaml', 'frappe_docker/overrides/compose.postgres.yaml', 'compose.generated.yml'):
        compose += ['-f', str(root / file)]
    config = json.loads(run(compose + ['config', '--format', 'json']))
    check_compose(config)
    containers = {name: run(compose + ['ps', '-q', name]).strip() for name in ('backend', 'frontend', 'tbi-query')}
    require(all(containers.values()), 'A required query deployment container is not running')
    states = {n: json.loads(run(['docker', 'inspect', c]))[0] for n, c in containers.items()}
    for name, state in states.items():
        require(state['State']['Running'], name + ' is not running')
        require(state['Config']['Image'] == config['services'][name]['image'], name + ' is not running the configured image')
    require(states['tbi-query']['Image'] == states['backend']['Image'], 'Running query image differs from backend')
    require(states['tbi-query']['State'].get('Health', {}).get('Status') == 'healthy', 'Query container is unhealthy')
    locations = run(['docker', 'exec', containers['tbi-query'], PYTHON, '-m', 'tbi.query_service', '--nginx-locations', '--upstream', 'tbi-query:8082', '--site-name', site])
    nginx = run(['docker', 'exec', containers['frontend'], 'nginx', '-T'])
    check_routes(nginx, query_paths(locations))
    run(['docker', 'exec', containers['backend'], PYTHON, '-c', "import json,urllib.request; r=urllib.request.urlopen('http://tbi-query:8082/healthz',timeout=5); assert json.load(r)=={'service':'tbi-query','ok':True}"])
    if engine_container:
        engine = json.loads(run(['docker', 'inspect', engine_container]))[0]
        env = dict(v.split('=', 1) for v in engine['Config']['Env'] if '=' in v)
        require(env.get('TBI_ENGINE_GATEWAY_BRIDGE_URL') == 'http://backend:8000/api/method/tbi.engine_gateway_bridge.exchange', 'Engine bridge must point to the ordinary backend')
    print(json.dumps({'ok': True, 'query_routes': len(query_paths(locations)), 'service': 'tbi-query'}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'check', 'verify'])
    parser.add_argument('--root', required=True)
    parser.add_argument('--image')
    parser.add_argument('--stack')
    parser.add_argument('--site')
    parser.add_argument('--engine-container')
    args = parser.parse_args()
    try:
        if args.action == 'prepare':
            import sys
            data = json.load(sys.stdin)
            print(json.dumps(configure(data['compose'], args.image, args.root, data['template'], data['locations'])))
        elif args.action == 'check':
            import sys
            data = json.load(sys.stdin)
            check_compose(data['compose'])
            check_routes(data['nginx'], query_paths(data['locations']))
            print('{"ok":true}')
        else:
            require(bool(args.stack and args.site), 'verify requires stack and site')
            verify(args.root, args.stack, args.site, args.engine_container)
    except (ValueError, KeyError, subprocess.TimeoutExpired) as error:
        # JSON decoding errors contain no source payload; subprocess errors are sanitized by run().
        parser.exit(1, f'TBI query deployment check failed: {error}\n')


if __name__ == '__main__':
    main()

import copy
import importlib.util
import unittest
from pathlib import Path

path = Path(__file__).resolve().parents[1] / 'multi-node/ansible/roles/frappe_stack/files/tbi_query_config.py'
spec = importlib.util.spec_from_file_location('tbi_query_config', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

PATHS = ['/api/method/tbi.bi.dashboard.execute_dashboard', '/api/v1/method/tbi.bi.dashboard.execute_dashboard', '/tbi/shared_chart']
LOCATIONS = '\n'.join('location = ' + p + ' {\nproxy_pass http://tbi-query:8082;\n}' for p in PATHS)
TEMPLATE = 'server {\nlocation /assets { try_files $uri =404; }\nlocation @webserver { proxy_pass http://backend-server; }\n}'


class QueryDeploymentTest(unittest.TestCase):
    def setUp(self):
        self.original = {'services': {
            'backend': {'environment': {'NO_PROXY': '*'}, 'volumes': ['/secrets/engine:/run/secrets/engine:ro']},
            'frontend': {'ports': ['127.0.0.1:8080:8080']},
            'queue-tai-runtime': {'command': 'bench worker --queue tai_runtime'},
        }}

    def prepare(self, locations=LOCATIONS):
        return module.configure(self.original, 'app@sha256:abc', '/stack', TEMPLATE, locations)

    def resolved(self):
        config = self.prepare()['compose']
        services = config['services']
        services['backend']['image'] = 'app@sha256:abc'
        services['backend']['volumes'].append('sites:' + module.SITES)
        for service in services.values():
            volumes = []
            for mount in service.get('volumes', []):
                source, target, *mode = mount.split(':')
                volumes.append({'type': 'bind' if source.startswith('/') else 'volume', 'source': source, 'target': target, 'read_only': mode == ['ro']})
            service['volumes'] = volumes
        return config

    def test_repair_preserves_unrelated_services_and_secrets(self):
        before = copy.deepcopy(self.original)
        result = self.prepare()
        self.assertEqual(self.original, before)
        services = result['compose']['services']
        self.assertEqual(services['queue-tai-runtime'], before['services']['queue-tai-runtime'])
        self.assertEqual(services['frontend']['ports'], before['services']['frontend']['ports'])
        self.assertIn('/secrets/engine:/run/secrets/engine:ro', services['tbi-query']['volumes'])
        self.assertNotIn('ports', services['tbi-query'])
        module.check_compose(self.resolved())
        module.check_routes(result['nginx'], PATHS)

    def test_reapplication_is_idempotent(self):
        one = self.prepare()
        two = module.configure(one['compose'], 'app@sha256:abc', '/stack', TEMPLATE, LOCATIONS)
        self.assertEqual(one, two)

    def test_incident_topology_without_query_service_is_rejected(self):
        config = self.resolved()
        del config['services']['tbi-query']
        with self.assertRaisesRegex(ValueError, 'independent query service'):
            module.check_compose(config)

    def test_query_container_alone_does_not_make_deployment_healthy(self):
        with self.assertRaisesRegex(ValueError, 'differ from the image contract'):
            module.check_routes(TEMPLATE, PATHS)
        with self.assertRaisesRegex(ValueError, 'differ from the image contract'):
            module.check_routes(self.prepare()['nginx'].replace(PATHS[1], '/api/method/wrong'), PATHS)

    def test_bridge_and_wildcard_query_routes_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Bridge must stay'):
            self.prepare(LOCATIONS + '\nlocation = /api/method/tbi.engine_gateway_bridge.exchange { proxy_pass http://tbi-query:8082; }')
        with self.assertRaisesRegex(ValueError, 'exact locations'):
            module.check_routes(self.prepare()['nginx'].replace('location = ' + PATHS[0], 'location /api/'), PATHS)

    def test_mismatched_image_missing_secret_or_public_port_is_rejected(self):
        for change in ('image', 'secret', 'port', 'dependency', 'health', 'sites'):
            with self.subTest(change=change):
                config = self.resolved()
                query = config['services']['tbi-query']
                if change == 'image': query['image'] = 'older-app'
                if change == 'secret': query['volumes'] = query['volumes'][:1]
                if change == 'sites': query['volumes'][0]['source'] = 'another-site'
                if change == 'port': query['ports'] = [{'published': 8082, 'target': 8082}]
                if change == 'dependency': del config['services']['frontend']['depends_on']
                if change == 'health': query['healthcheck']['disable'] = True
                with self.assertRaises(ValueError): module.check_compose(config)

    def test_old_image_without_query_contract_cannot_be_deployed(self):
        with self.assertRaisesRegex(ValueError, 'empty or duplicated'):
            self.prepare('')


if __name__ == '__main__':
    unittest.main()

from datetime import datetime
import requests
import logging
import random
import string
from locust import HttpUser, SequentialTaskSet, task, events, between
import time
import subprocess
import uuid
import locust_plugins
from locust.clients import HttpSession
from locust.exception import StopUser
from requests.packages.urllib3.exceptions import InsecureRequestWarning

requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

# These two lines enable debugging at httplib level (requests->urllib3->http.client)
# You will see the REQUEST, including HEADERS and DATA, and RESPONSE with HEADERS but without DATA.
# The only thing missing will be the response.body which is not logged.
# import http.client as http_client

# http_client.HTTPConnection.debuglevel = 1

# You must initialize logging, otherwise you'll not see debug output.
# logging.basicConfig()
# logging.getLogger().setLevel(logging.DEBUG)
# requests_log = logging.getLogger("requests.packages.urllib3")
# requests_log.setLevel(logging.DEBUG)
# requests_log.propagate = True

import locust.stats

locust.stats.CSV_STATS_INTERVAL_SEC = 5  # default is 1 second
locust.stats.CSV_STATS_FLUSH_INTERVAL_SEC = 60  # Determines how often the data is flushed to disk, default is 10 seconds


def get_random_string(length):
    # choose from all lowercase letter
    letters = string.ascii_lowercase
    return ''.join(random.choice(letters) for i in range(length))


# from jtl_listener import JtlListener
# @events.init.add_listener
# def on_locust_init(environment, **_kwargs):
#    JtlListener(env=environment)

@events.init_command_line_parser.add_listener
def _(parser):
    parser.add_argument("--certs-folder", type=str,
                        env_var="CERTS_FOLDER", default="", help="Certificates folder")
    parser.add_argument("--registration-folder", type=str,
                        env_var="REGISTRATION_FOLDER", default="", help="Registration folder")
    parser.add_argument("--heartbeat-folder", type=str,
                        env_var="HEARTBEAT_FOLDER", default="", help="Heartbeat folder")
    parser.add_argument("--get-updates-folder", type=str,
                        env_var="GET_UPDATES_FOLDER", default="", help="Get updates folder")
    parser.add_argument("--enrol-folder", type=str,
                        env_var="ENROL_FOLDER", default="", help="Enrol folder")
    parser.add_argument("--https-server", type=str, env_var="HTTPS_SERVER",
                        default="", help="FLotta operator server")
    parser.add_argument("--https-server-port", type=str, env_var="HTTPS_SERVER_PORT",
                        default="", help="FLotta operator server port")
    parser.add_argument("--ocp-api-server", type=str,
                        env_var="OCP_API_SERVER", default="", help="OCP API server")
    parser.add_argument("--ocp-api-port", type=str,
                        env_var="OCP_API_PORT", default="", help="OCP API port")
    parser.add_argument("--test-dir", type=str, env_var="TEST_DIR",
                        default="", help="Directory of the test")
    parser.add_argument("--deployment-per-device", type=str,
                        env_var="EDGE_DEPLOYMENTS_PER_DEVICE", default="", help="Deployment per device")
    parser.add_argument("--target-namespace", type=str,
                        env_var="TARGET_NAMESPACE", default="", help="Target namespace for edgedevices")
    parser.add_argument("--k8s-bearer-token", type=str,
                        env_var="K8S_BEARER_TOKEN", default="", help="K8S bearer token")
    parser.add_argument("--test-iterations", type=str,
                        env_var="TEST_ITERATIONS", default="", help="Iterations to run get_updates and send_heartbeat")


DEFAULT_LABEL = "region"


@events.test_start.add_listener
def _(environment, **kw):
    print("Custom argument supplied: %s" %
          environment.parsed_options)


class QuickstartUser(HttpUser):

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.enrol_success = False
        self.register_success = False

    @task
    def execute_test_plan(self):
        self.device_id = str(uuid.uuid4())
        self.default_ca_path = f"{self.environment.parsed_options.certs_folder}/default_ca.pem"
        self.default_key_path = f"{self.environment.parsed_options.certs_folder}/default_key.pem"
        self.default_cert_path = f"{self.environment.parsed_options.certs_folder}/default_cert.pem"
        self.https_server = self.environment.parsed_options.https_server
        self.https_server_port = self.environment.parsed_options.https_server_port
        self.product_name = get_random_string(10)
        self.serial_number = get_random_string(10)
        self.hostname = get_random_string(10) + '.flotta'
        self.k8s_bearer_token = self.environment.parsed_options.k8s_bearer_token
        self.ocp_api_server = self.environment.parsed_options.ocp_api_server
        self.ocp_api_port = self.environment.parsed_options.ocp_api_port
        self.target_namespace = self.environment.parsed_options.target_namespace
        self.device_key_path = f"{self.environment.parsed_options.certs_folder}/{self.device_id}.key"
        self.device_cert_path = f"{self.environment.parsed_options.certs_folder}/{self.device_id}.pem"
        self.deployment_per_device = int(self.environment.parsed_options.deployment_per_device)
        self.test_iterations = int(self.environment.parsed_options.test_iterations)

        self.enrol()
        self.approve()
        self.register()
        self.label()
        self.create_workload()
        self.iterates()
        assert self.cnt <= 9, f"REGISTER, Max retries reached: {self.cnt}"

    def enrol(self):
        # print(f"Device {self.device_id};  enrol")
        enrol_paylod = {
            "content": {
                "target_namespace": self.target_namespace,
                "features": {
                    "hardware": {
                        "cpu": {
                            "architecture": "x86_64",
                            "flags": [

                            ],
                            "model_name": "Intel(R) Core(TM) i7-6820HQ CPU @ 2.70GHz"
                        },
                        "hostname": self.hostname,
                        "system_vendor": {
                            "manufacturer": "LENOVO",
                            "product_name": self.product_name,
                            "serial_number": self.serial_number
                        }
                    },
                    "os_image_id": "unknown"
                }
            },
            "directive": "enrolment",
            "message_id": str(uuid.uuid4()),
            "sent": "2021-11-21T14:45:25.271+02:00",
            "type": "data",
            "version": 1
        }
        r = self.client.post(
            f"https://{self.https_server}:{self.https_server_port}/api/flotta-management/v1/data/{self.device_id}/out",
            json=enrol_paylod, cert=(self.default_cert_path, self.default_key_path), verify=self.default_ca_path,
            name=f"enrol")
        status_code = r.status_code
        assert status_code == 200, f"ENROL, Expected status code to be 200, was {status_code}; DeviceId: {self.device_id}"
        self.enrol_success = True

    def approve(self):
        # print(f"DeviceID: {self.device_id}, approve; {self.k8s_bearer_token}")
        json = {
            "spec": {
                "approved": True
            }
        }
        r = self.client.patch(
            f"https://{self.ocp_api_server}:{self.ocp_api_port}/apis/management.project-flotta.io/v1alpha1/namespaces/{self.target_namespace}/edgedevicesignedrequest/{self.device_id}",
            headers={"Content-Type": "application/merge-patch+json", "Cache-Control": "no-cache",
                     "Authorization": f"Bearer {self.k8s_bearer_token}"}, json=json, verify=False,
            name=f"approve")
        while r.status_code != 200:
            time.sleep(random.randint(30, 45))
            r = self.client.patch(
                f"https://{self.ocp_api_server}:{self.ocp_api_port}/apis/management.project-flotta.io/v1alpha1/namespaces/{self.target_namespace}/edgedevicesignedrequest/{self.device_id}",
                headers={"Content-Type": "application/merge-patch+json", "Cache-Control": "no-cache",
                         "Authorization": f"Bearer {self.k8s_bearer_token}"}, json=json, verify=False,
                name=f"approve")
        assert r.status_code == 200, f"APPROVE, Expected status code to be == 200, was {r.status_code}, {r.text}; DeviceId: {self.device_id}"

    def register(self):
        assert self.enrol_success, f"REGISTER, Enrol did not succeed; DeviceId: {self.device_id}"
        # print(f"Device {self.device_id}; register")
        device_cert_request_path = f"{self.environment.parsed_options.certs_folder}/{self.device_id}.csr"
        # print(f"Device {self.device_id}; register; generating keys")
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1",
                        "-genkey", "-noout", "-out", self.device_key_path])
        subprocess.run(["openssl", "req", "-new", "-subj",
                        f"/CN={self.device_id}", "-key", self.device_key_path, "-out", device_cert_request_path])
        # print(f"Device {self.device_id};  register; generating keys OK")
        with open(device_cert_request_path) as csr_file:
            certificate_request = csr_file.read().replace('$', '\n')
            register_payload = {
                "content": {
                    "certificate_request": f"{certificate_request}",
                    "hardware": {
                        "cpu": {
                            "architecture": "x86_64",
                            "flags": [],
                            "model_name": "Intel(R) Core(TM) i7-6820HQ CPU @ 2.70GHz"
                        },
                        "hostname": self.hostname,
                        "system_vendor": {
                            "manufacturer": "LENOVO",
                            "product_name": self.product_name,
                            "serial_number": self.serial_number
                        }
                    },
                    "os_image_id": "unknown"
                },
                "directive": "registration",
                "message_id": str(uuid.uuid4()),
                "sent": "2021-11-21T14:45:25.271+02:00",
                "type": "data",
                "version": 1
            }
            # print(f"Device {self.device_id}; register; sending payload")
            cnt, r = self.send_register_request(register_payload)
            # print(f"Device {self.device_id}; Retries to register: {cnt}")
            assert r.status_code == 200, f"REGISTER, Expected status code to be == 200, was {r.status_code}, {r.text}; DeviceId: {self.device_id}"
            cert = r.json()["content"]["certificate"]
            # print(f"\nDevice {self.device_id} success, writing cert to {device_cert_path}\n")
            with open(self.device_cert_path, 'w') as pem_file:
                pem_file.write(cert)
                self.register_success = True

    def send_register_request(self, register_payload):
        self.cnt = 1
        r = self.client.post(
            f"https://{self.https_server}:{self.https_server_port}/api/flotta-management/v1/data/{self.device_id}/out",
            headers={"Content-Type": "application/json"}, json=register_payload,
            cert=(self.default_cert_path, self.default_key_path), verify=self.default_ca_path,
            name=f"register")
        while r.status_code == 404:
            # print(f"\nDevice {self.device_id} retrying: {cnt}/5\n")
            time.sleep(random.randint(30, 45))
            r = self.client.post(
                f"https://{self.https_server}:{self.https_server_port}/api/flotta-management/v1/data/{self.device_id}/out",
                json=register_payload, cert=(self.default_cert_path, self.default_key_path),
                verify=self.default_ca_path, name=f"register")
            if r.status_code != 404:
                self.cnt = self.cnt + 1
                # assert cnt <= 9, f"Max retries reached: {cnt}, status: {r.status_code}; DeviceID: {self.device_id}"
        return self.cnt, r

    def label(self):
        assert self.register_success, f"LABEL, Register did not succeed; skipping label task; DeviceId: {self.device_id}"
        # print(f"DeviceID: {self.device_id}, label")
        # print(
        #    f"https://{self.ocp_api_server}:{self.ocp_api_port}/apis/management.project-flotta.io/v1alpha1/namespaces/{self.target_namespace}/edgedevices/{self.device_id}")
        json = {
            "metadata": {
                "labels": {
                    f"{DEFAULT_LABEL}": f"{self.device_id}"
                }
            }
        }
        r = self.client.patch(
            f"https://{self.ocp_api_server}:{self.ocp_api_port}/apis/management.project-flotta.io/v1alpha1/namespaces/{self.target_namespace}/edgedevices/{self.device_id}",
            headers={"Content-Type": "application/merge-patch+json", "Cache-Control": "no-cache",
                     "Authorization": f"Bearer {self.k8s_bearer_token}"}, json=json, verify=False,
            name=f"label")
        assert r.status_code == 200, f"LABEL, Expected status code to be == 200, was {r.status_code}, {r.text}; DeviceId: {self.device_id}"

    def create_workload(self):
        assert self.register_success, f"WORKLOAD, Register did not succeed; skipping create_workload task; DeviceId: {self.device_id}"
        # print(f"DeviceID: {self.device_id}, create_workload; worklaod to create: {self.deployment_per_device}")

        for i in range(0, self.deployment_per_device):
            json = {
                "apiVersion": "management.project-flotta.io/v1alpha1",
                "kind": "EdgeWorkload",
                "metadata": {
                    "name": f"{self.device_id}-{i}",
                    "namespace": f"{self.target_namespace}"
                },
                "spec": {
                    "data": {
                        "paths": [
                            {
                                "source": ".",
                                "target": "nginx"
                            }
                        ]
                    },
                    "deviceSelector": {
                        "matchLabels": {
                            f"{DEFAULT_LABEL}": f"{self.device_id}"
                        }
                    },
                    "pod": {
                        "spec": {
                            "containers": [
                                {
                                    "image": "docker.io/nginx:1.14.2",
                                    "name": "nginx",
                                    "ports": [
                                        {
                                            "containerPort": 80,
                                            "hostPort": 9090,
                                            "protocol": "TCP"
                                        }
                                    ]
                                }
                            ]
                        }
                    },
                    "type": "pod"
                }
            }
            r = self.client.post(
                f"https://{self.ocp_api_server}:{self.ocp_api_port}/apis/management.project-flotta.io/v1alpha1/namespaces/{self.target_namespace}/edgeworkloads",
                headers={"Content-Type": "application/json", "Cache-Control": "no-cache",
                         "Authorization": f"Bearer {self.k8s_bearer_token}"}, json=json, verify=False,
                name=f"create workload-{i}")
            assert r.status_code == 201, f"WORKLOAD, Expected status code to be == 201, was {r.status_code}, {r.text}; DeviceId: {self.device_id}"

    def iterates(self):
        assert self.register_success, f"ITERATES, Register did not succeed; skipping iterates task; DeviceId: {self.device_id}"
        self.registered_client = HttpSession(
            base_url=self.host,
            request_event=self.environment.events.request,
            user=self,
            pool_manager=self.pool_manager,
        )

        time.sleep(5)
        # print(f"DeviceID: {self.device_id}, iterates; {self.test_iterations} times")
        for i in range(0, self.test_iterations):
            self.get_updates()
            self.send_heartbeat()

    def get_updates(self):
        # print(
        #    f"DeviceID: {self.device_id}, get_updates; https://{self.https_server}:{self.https_server_port}/api/flotta-management/v1/data/{self.device_id}/in")
        # print(
        #    f"self.registered_client.get(https://{self.https_server}:{self.https_server_port}/api/flotta-management/v1/data/{self.device_id}/in,cert=({self.device_cert_path}, {self.device_key_path}), verify={self.default_ca_path})")
        for i in range(0, 4):
            if i > 0:
                time.sleep(15)
            r = self.registered_client.get(
                f"https://{self.https_server}:{self.https_server_port}/api/flotta-management/v1/data/{self.device_id}/in",
                cert=(self.device_cert_path, self.device_key_path), verify=self.default_ca_path,  headers={'Connection':'close'},
                name=f"get_updates-{i}")
            # assert r.status_code == 200, f"Expected status code to be == 200, was {r.status_code}, {r.text}"
            # print(r.status_code)
            # print(r.text)

    def send_heartbeat(self):
        # print(f"DeviceID: {self.device_id}, send_heartbeat")
        json = {
            "content": {
                "events": [
                    {
                        "message": "error starting container f8433cc4b0c963ce95625ab3b1811382f852432f61a2d087422210e9d34bc2bc: cannot listen on the TCP port: listen tcp4 :11000: bind: address already in use,error starting container 7cd64802bde9d6b9dd425d79ea68eb49546e5fc87d0dce474c7515e81f448d50: a dependency of container 7cd64802bde9d6b9dd425d79ea68eb49546e5fc87d0dce474c7515e81f448d50 failed to start: container state improper",
                        "reason": "Failed",
                        "type": "warn"
                    },
                    {
                        "message": "error starting container f8433cc4b0c963ce95625ab3b1811382f852432f61a2d087422210e9d34bc2bc: cannot listen on the TCP port: listen tcp4 :11000: bind: address already in use,error starting container 7cd64802bde9d6b9dd425d79ea68eb49546e5fc87d0dce474c7515e81f448d50: a dependency of container 7cd64802bde9d6b9dd425d79ea68eb49546e5fc87d0dce474c7515e81f448d50 failed to start: container state improper",
                        "reason": "Failed",
                        "type": "warn"
                    },
                    {
                        "message": "error starting container f8433cc4b0c963ce95625ab3b1811382f852432f61a2d087422210e9d34bc2bc: cannot listen on the TCP port: listen tcp4 :11000: bind: address already in use,error starting container 7cd64802bde9d6b9dd425d79ea68eb49546e5fc87d0dce474c7515e81f448d50: a dependency of container 7cd64802bde9d6b9dd425d79ea68eb49546e5fc87d0dce474c7515e81f448d50 failed to start: container state improper",
                        "reason": "Failed",
                        "type": "warn"
                    },
                    {
                        "message": "error starting container f8433cc4b0c963ce95625ab3b1811382f852432f61a2d087422210e9d34bc2bc: cannot listen on the TCP port: listen tcp4 :11000: bind: address already in use,error starting container 7cd64802bde9d6b9dd425d79ea68eb49546e5fc87d0dce474c7515e81f448d50: a dependency of container 7cd64802bde9d6b9dd425d79ea68eb49546e5fc87d0dce474c7515e81f448d50 failed to start: container state improper",
                        "reason": "Failed",
                        "type": "warn"
                    }
                ],
                "status": "up",
                "time": f"{datetime.today().isoformat()}Z",
                "version": "278650",
                "workloads": [
                    {
                        "last_data_upload": "0001-01-01T00:00:00.000Z",
                        "name": f"{self.device_id}-1",
                        "status": "Running"
                    },
                    {
                        "last_data_upload": "0001-01-01T00:00:00.000Z",
                        "name": f"{self.device_id}-2",
                        "status": "Created"
                    },
                    {
                        "last_data_upload": "0001-01-01T00:00:00.000Z",
                        "name": f"{self.device_id}-3",
                        "status": "Running"
                    },
                    {
                        "last_data_upload": "0001-01-01T00:00:00.000Z",
                        "name": f"{self.device_id}-4",
                        "status": "Created"
                    },
                    {
                        "last_data_upload": "0001-01-01T00:00:00.000Z",
                        "name": f"{self.device_id}-5",
                        "status": "Running"
                    },
                    {
                        "last_data_upload": "0001-01-01T00:00:00.000Z",
                        "name": f"{self.device_id}-6",
                        "status": "Created"
                    },
                    {
                        "last_data_upload": "0001-01-01T00:00:00.000Z",
                        "name": f"{self.device_id}-7",
                        "status": "Running"
                    },
                    {
                        "last_data_upload": "0001-01-01T00:00:00.000Z",
                        "name": f"{self.device_id}-8",
                        "status": "Created"
                    },
                    {
                        "last_data_upload": "0001-01-01T00:00:00.000Z",
                        "name": f"{self.device_id}-9",
                        "status": "Running"
                    }
                ]
            },
            "directive": "heartbeat",
            "message_id": str(uuid.uuid4()),
            "type": "data",
            "version": 1
        }
        # print(
        #    f"DeviceID: {self.device_id}, send_heartbeat; https://{self.https_server}:{self.https_server_port}/api/flotta-management/v1/data/{self.device_id}/out")
        # print(f"DeviceID: {self.device_id}, send_heartbeat; {json}")
        r = self.registered_client.post(
            f"https://{self.https_server}:{self.https_server_port}/api/flotta-management/v1/data/{self.device_id}/out",
            headers={"Content-Type": "application/json", 'Connection':'close'}, json=json,
            cert=(self.device_cert_path, self.device_key_path), verify=self.default_ca_path,
            name=f"heartbeat")
        # print(r.status_code)
        # print(r.text)


from locust.env import Environment

if __name__ == '__main__':
    env = Environment()
    QuickstartUser(env).run()

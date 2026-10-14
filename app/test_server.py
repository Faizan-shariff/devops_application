import json
import threading
import unittest
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import urlopen
from app.server import Handler

class HTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def request(self, path):
        with urlopen(f"http://127.0.0.1:{self.port}{path}") as response:
            return response.status, response.headers, json.load(response)

    def test_root(self):
        status, headers, body = self.request("/")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get_content_type(), "application/json")
        self.assertEqual(body["service"], "logikality-document-api")

    def test_health(self):
        status, _, body = self.request("/health")
        self.assertEqual(status, 200)
        self.assertEqual(body, {"status": "healthy"})

    def test_404(self):
        with self.assertRaises(HTTPError) as error:
            urlopen(f"http://127.0.0.1:{self.port}/missing")
        self.assertEqual(error.exception.code, 404)

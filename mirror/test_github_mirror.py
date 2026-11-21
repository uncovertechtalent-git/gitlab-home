import importlib.util
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("gm", pathlib.Path(__file__).with_name("github-mirror.py"))
gm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gm)


class Helpers(unittest.TestCase):
    def test_load_env(self):
        with tempfile.NamedTemporaryFile("w", suffix=".env") as f:
            f.write('# comment\n\nOWNERS="a b"\nGITLAB_GROUP=github\nNOEQUALS\n')
            f.flush()
            self.assertEqual(gm.load_env(f.name), {"OWNERS": "a b", "GITLAB_GROUP": "github"})

    def test_next_link(self):
        h = '<https://api.github.com/x?page=2>; rel="next", <https://api.github.com/x?page=9>; rel="last"'
        self.assertEqual(gm.next_link(h), "https://api.github.com/x?page=2")
        self.assertIsNone(gm.next_link('<https://api.github.com/x?page=1>; rel="prev"'))
        self.assertIsNone(gm.next_link(None))

    def test_project_path(self):
        self.assertEqual(gm.project_path("machinebehavior.io"), "machinebehavior.io")
        self.assertEqual(gm.project_path("squid_docker"), "squid_docker")
        self.assertEqual(gm.project_path("weird.git"), "weird-git")
        self.assertEqual(gm.project_path("a b"), "a-b")

    def test_credentials(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d)
            (p / "github-mirror.gitlab_token").write_text("glpat-x\n")
            (p / "github-mirror.token.someone").write_text("ghp-y\n")
            (p / "unrelated").write_text("z")
            self.assertEqual(gm.load_credentials(d), {"gitlab_token": "glpat-x", "token.someone": "ghp-y"})
        self.assertEqual(gm.load_credentials(None), {})


if __name__ == "__main__":
    unittest.main()

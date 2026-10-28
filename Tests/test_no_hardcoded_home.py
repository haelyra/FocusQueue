import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
# A literal macOS home folder ties a script to one user's machine.
HOME_LITERAL = re.compile(r"/Users/[A-Za-z0-9._-]+/")


class NoHardcodedHomeTests(unittest.TestCase):
    def test_shipped_scripts_and_sources_derive_home_paths(self):
        offenders = []
        for directory in ("Scripts", "Sources"):
            for path in sorted((ROOT / directory).rglob("*")):
                if not path.is_file() or "__pycache__" in path.parts:
                    continue
                try:
                    text = path.read_text(encoding="utf-8")
                except UnicodeDecodeError:
                    continue
                for number, line in enumerate(text.splitlines(), 1):
                    if HOME_LITERAL.search(line):
                        offenders.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
        self.assertEqual(offenders, [], "\n".join(offenders))


if __name__ == "__main__":
    unittest.main()
